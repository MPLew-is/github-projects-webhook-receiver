import Foundation

import AsyncHTTPClient
import AWSDynamoDB
import AWSLambdaEvents
import AWSLambdaRuntime
import AWSSecretsManager
import BigInt
import Crypto
import DeepCodable
import GithubApiClient
import SlackMessageClient


/// Data contained by all GitHub App webhook events, such as the installation ID
struct BaseWebhookEvent: DeepDecodable {
	static let codingTree = CodingTree {
		Key("installation") {
			Key("id", containing: \._installationId)
		}
	}

	@Value var installationId: Int
}


/// Failure scenarios during the Lambda's processing of the webhook event
enum LambdaInitializationError: Error, CustomStringConvertible {
	/**
	A required environment variable was not set

	This case has the name of the missing environment variable attached to it for debugging purposes.
	*/
	case environmentVariableNotFound(variable: String)
	/**
	A required AWS Secrets Manager secret had no value

	This case has a human-friendly description and ARN for the secret attached to it for debugging purposes.
	*/
	case secretNil(description: String, arn: String)
	/**
	A required AWS Secrets Manager secret could not be decoded from UTF-8

	This case has a human-friendly description and ARN for the secret attached to it for debugging purposes.
	*/
	case secretNotUtf8(description: String, arn: String)

	var description: String {
		switch self {
			case .environmentVariableNotFound(let variable):
				return "Environment variable not found: \(variable)"

			case .secretNil(let name, let arn):
				return "AWS Secrets Manager Secret for value '\(name)' returned an empty value, tried to access ARN: \(arn)"

			case .secretNotUtf8(let name, let arn):
				return "AWS Secrets Manager Secret for value '\(name)' could not be decoded as UTF-8, tried to access ARN: \(arn)"
		}
	}
}


/// Required GitHub credentials, to be decoded from an AWS Secrets Manager response
struct GithubCredentials: Decodable {
	/// GitHub App ID that is being used to authenticate to the GitHub API
	let appId: String
	/// PEM-encoded GitHub App private key, to sign authentication tokens for API access
	let privateKey: String
	/// HMAC shared secret for [verifying webhook bodies](https://docs.github.com/en/developers/webhooks-and-events/webhooks/securing-your-webhooks)
	let webhookSecret: String
}

/// Required Slack credentials, to be decoded from an AWS Secrets Manager response
struct SlackCredentials: Decodable {
	/// Slack Bot token, to perform actions as a Slack App
	let botToken: String
}

/// Required GitHub/Slack configuration, to be decoded from an AWS Secrets Manager response
struct Configuration: Decodable {
	/// GraphQL node ID of the GitHub Project being watched for changes
	let githubProjectId: String
	/// GraphQL node ID of the GitHub Project field being watched for changes
	let githubProjectFieldId: String
	/// GitHub repository to be watched for issue comments
	let githubRepository: String

	/// Slack Channel ID where messages should be sent
	let slackChannelId: String
}


/// Lambda handler that responds to direct [function URL invocations](https://docs.aws.amazon.com/lambda/latest/dg/lambda-urls.html)
@main
final class FunctionUrlLambdaHandler: LambdaHandler {
	/// Stored client for making asynchronous HTTP requests
	let httpClient: HTTPClient

	/// Stored DynamoDB client
	let dynamoDbClient: DynamoDbClient


	/// Stored client for interfacing with the GitHub API
	let githubClient: GithubApiClient

	/// HMAC shared secret to verify webhook payloads
	let githubWebhookSecret: Data
	/// GraphQL node ID of the GitHub Project being watched for changes
	let githubProjectId: String
	/// GraphQL node ID of the GitHub Project field being watched for changes
	let githubProjectFieldId: String
	/// GitHub repository to be watched for issue comments
	let githubRepository: String


	/// Stored client for interfacing with the Slack API
	let slackClient: SlackMessageClient

	/// Slack channel ID to sent messages to
	let slackChannelId: String


	init(context: LambdaInitializationContext) async throws {
		context.logger.info("Creating AWS service clients")
		guard let region = Lambda.env("REGION") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "REGION")
		}
		let secretsManagerClient: SecretsManagerClient = try .init(region: region)
		self.dynamoDbClient = try .init(region: region)


		// Use a single decoder for all the decoding below, for performance.
		let decoder: JSONDecoder = .init()

		/*
		Fetch and decode the values of required secrets, from ARNs provided via environment variables.
		These seem to have to be sequential to avoid segfaults, but could in theory be transformed into `async let` statements to exploit concurrency.
		*/
		context.logger.info("Fetching GitHub Credentials")
		guard let githubCredentials_secretArn = Lambda.env("GITHUB_CREDENTIALS_SECRET_ARN") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "GITHUB_CREDENTIALS_SECRET_ARN")
		}
		let githubCredentials_secretRequest: GetSecretValueInput = .init(secretId: githubCredentials_secretArn)
		let githubCredentials_secretResponse = try await secretsManagerClient.getSecretValue(input: githubCredentials_secretRequest)

		context.logger.info("Decoding GitHub Credentials")
		guard let githubCredentials_string = githubCredentials_secretResponse.secretString else {
			throw LambdaInitializationError.secretNil(description: "Github credentials", arn: githubCredentials_secretArn)
		}
		guard let githubCredentials_data = githubCredentials_string.data(using: .utf8) else {
			throw LambdaInitializationError.secretNotUtf8(description: "Github credentials", arn: githubCredentials_secretArn)
		}
		let githubCredentials = try decoder.decode(GithubCredentials.self, from: githubCredentials_data)


		context.logger.info("Fetching Slack Credentials")
		guard let slackCredentials_secretArn = Lambda.env("SLACK_CREDENTIALS_SECRET_ARN") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "SLACK_CREDENTIALS_SECRET_ARN")
		}
		let slackCredentials_secretRequest: GetSecretValueInput = .init(secretId: slackCredentials_secretArn)
		let slackCredentials_secretResponse = try await secretsManagerClient.getSecretValue(input: slackCredentials_secretRequest)

		context.logger.info("Decoding Slack Credentials")
		guard let slackCredentials_string = slackCredentials_secretResponse.secretString else {
			throw LambdaInitializationError.secretNil(description: "Slack credentials", arn: slackCredentials_secretArn)
		}
		guard let slackCredentials_data = slackCredentials_string.data(using: .utf8) else {
			throw LambdaInitializationError.secretNotUtf8(description: "Slack credentials", arn: slackCredentials_secretArn)
		}
		let slackCredentials = try decoder.decode(SlackCredentials.self, from: slackCredentials_data)


		context.logger.info("Fetching Lambda configuration")
		guard let configuration_secretArn = Lambda.env("CONFIGURATION_SECRET_ARN") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "CONFIGURATION_SECRET_ARN")
		}
		let configuration_secretRequest: GetSecretValueInput = .init(secretId: configuration_secretArn)
		let configuration_secretResponse = try await secretsManagerClient.getSecretValue(input: configuration_secretRequest)

		context.logger.info("Decoding Lambda configuration")
		guard let configuration_string = configuration_secretResponse.secretString else {
			throw LambdaInitializationError.secretNil(description: "Lambda configuration", arn: configuration_secretArn)
		}
		guard let configuration_data = configuration_string.data(using: .utf8) else {
			throw LambdaInitializationError.secretNotUtf8(description: "Lambda configuration", arn: configuration_secretArn)
		}
		let configuration = try decoder.decode(Configuration.self, from: configuration_data)


		context.logger.info("Creating underlying API clients")

		self.httpClient = .init(eventLoopGroupProvider: .createNew)


		self.githubClient = try .init(
			appId: githubCredentials.appId,
			privateKey: githubCredentials.privateKey,
			httpClient: httpClient
		)

		// We already verified the entire blob containing this item could be decoded to data as UTF-8, no need to check again.
		self.githubWebhookSecret = githubCredentials.webhookSecret.data(using: .utf8)!

		self.githubProjectId = configuration.githubProjectId
		self.githubProjectFieldId = configuration.githubProjectFieldId
		self.githubRepository = configuration.githubRepository


		self.slackClient = .init(
			authToken: slackCredentials.botToken,
			httpClient: httpClient
		)

		self.slackChannelId = configuration.slackChannelId
	}

	deinit {
		try? self.httpClient.syncShutdown()
	}


	typealias Event  = FunctionURLRequest
	typealias Output = FunctionURLResponse

	/// Prefix for actual signature in the event received from GitHub, for centralization purposes.
	static let signaturePrefix = "sha256="

	func handle(_ event: Event, context: LambdaContext) async throws -> Output {
		// This should always have a payload, or we have nothing to process.
		guard let payload_string = event.body else {
			context.logger.error("Payload has no body")
			return .init(statusCode: .badRequest)
		}

		guard let eventName = event.headers["x-github-event"] else {
			context.logger.error("Payload did not include event name, dumping headers: \(event.headers)")
			return .init(statusCode: .badRequest)
		}

		guard let signature_prefixedString = event.headers["x-hub-signature-256"] else {
			context.logger.error("Payload has no signature, dumping headers: \(event.headers)")
			return .init(statusCode: .badRequest)
		}

		guard signature_prefixedString.hasPrefix(Self.signaturePrefix) else {
			context.logger.error("Payload's signature is not prefixed with required string '\(Self.signaturePrefix)': \(signature_prefixedString)")
			return .init(statusCode: .badRequest)
		}

		let signature_string = signature_prefixedString.dropFirst(Self.signaturePrefix.count)
		guard let signature_uint = BigUInt(signature_string, radix: 16) else {
			context.logger.error("Payload's signature is not hex-encoded")
			return .init(statusCode: .badRequest)
		}

		let payload_data: Data?
		if event.isBase64Encoded {
			payload_data = .init(base64Encoded: payload_string)
		}
		else {
			payload_data = payload_string.data(using: .utf8)
		}
		guard let payload_data = payload_data else {
			let encoding: String = event.isBase64Encoded ? "base-64" : "UTF-8"
			context.logger.error("Payload body could not be decoded from \(encoding) encoded string: \(payload_string)")
			return .init(statusCode: .badRequest)
		}

		guard HMAC<SHA256>.isValidAuthenticationCode(signature_uint.serialize(), authenticating: payload_data, using: .init(data: self.githubWebhookSecret)) else {
			context.logger.error("Payload body did not pass signature verification")
			return .init(statusCode: .badRequest)
		}

		/*
		Interpreting the payload as a base event, extract the installation ID from the webhook.
		This way, we can both not have to configure the installation ID/login ahead of time, and can support multiple.
		*/
		let installationId: Int
		do {
			let basePayload = try JSONDecoder().decode(BaseWebhookEvent.self, from: payload_data)
			installationId = basePayload.installationId
		}
		catch {
			context.logger.error("Payload body could not be decoded even to a base webhook event")
			return .init(statusCode: .badRequest)
		}


		// Once decoded and validated, route events to the appropriate handler.
		switch eventName {
			case "projects_v2_item":
				return try await self.handleProjectsItem(payload: payload_data, context: context, installationId: installationId)

			case "issue_comment":
				return try await self.handleIssueComment(payload: payload_data, context: context, installationId: installationId)

			default:
				context.logger.error("Unrecognized event: \(eventName)")
				// Specifically surface this to the GitHub webhooks console, so we can find out pretty quickly when we receive another event type.
				return .init(statusCode: .unprocessableEntity)
		}
	}
}
