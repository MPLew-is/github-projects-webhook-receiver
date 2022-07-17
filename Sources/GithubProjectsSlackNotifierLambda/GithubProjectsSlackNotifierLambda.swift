import Foundation

import AWSLambdaEvents
import AWSLambdaRuntime
import AWSSecretsManager
import DeepCodable

import GithubProjectsSlackNotifier


/// Object representing data received in a GitHub `projects_v2_item` webhook request
struct GithubProjectsWebhookRequest: DeepDecodable {
	static let codingTree = CodingTree {
		Key("action", containing: \._action)

		Key("projects_v2_item") {
			Key("node_id", containing: \._itemId)
			Key("project_node_id", containing: \._projectId)
		}

		Key("changes") {
			Key("field_value") {
				Key("field_node_id", containing: \._fieldId)
			}
		}

		Key("sender") {
			Key("login", containing: \._username)
		}
	}

	/// Action this event is informing us about (`edited`, `created`, `reordered`, etc.)
	@Value var action: String
	/// Username performing the action
	@Value var username: String

	/// GraphQL node ID for the item that is the subject of this event
	@Value var itemId: String
	/// GraphQL node ID for the project containing the subject item
	@Value var projectId: String
	/// GraphQL node ID for the field modified on the item (only present when the action is `edited`)
	@Value var fieldId: String?
}


/// Error type representing failure scenarios during the Lambda's processing of the webhook event
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


/// Object representing required GitHub credentials, to be decoded from an AWS Secrets Manager response
struct GithubCredentials: Decodable {
	/// GitHub App ID that is being used to authenticate to the GitHub API
	let appId: String
	/// PEM-encoded GitHub App private key, to sign authentication tokens for API access
	let privateKey: String
}

/// Object representing required Slack credentials, to be decoded from an AWS Secrets Manager response
struct SlackCredentials: Decodable {
	/// Slack Bot token, to perform actions as a Slack App
	let botToken: String
}

/// Object representing required GitHub/Slack configuration, to be decoded from an AWS Secrets Manager response
struct GithubSlackConfiguration: Decodable {
	/// GraphQL node ID of the GitHub Project being watched for changes
	let githubProjectId: String
	/// GraphQL node ID of the GitHub Project field being watched for changes
	let githubProjectFieldId: String

	/// Slack Channel ID where messages should be sent
	let slackChannelId: String
}


@main
struct DirectLambdaHandler: LambdaHandler {
	/// Stored client for interfacing with both the GitHub and Slack APIs for sending project change notifications
	let notifier: GithubProjectsSlackNotifier

	/// GraphQL node ID of the GitHub Project being watched for changes
	let githubProjectId: String
	/// GraphQL node ID of the GitHub Project field being watched for changes
	let githubProjectFieldId: String

	init(context _: LambdaInitializationContext) async throws {
		/*
		Create an AWS Secrets Manager client for the current region.
		*/
		guard let region = Lambda.env("REGION") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "REGION")
		}
		let secretsManagerClient: SecretsManagerClient = try .init(region: region)


		/*
		Start fetching the values of required secrets, from ARNs provided via environment variables.
		*/
		guard let githubCredentials_secretArn = Lambda.env("GITHUB_CREDENTIALS_SECRET_ARN") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "GITHUB_CREDENTIALS_SECRET_ARN")
		}
		let githubCredentials_secretRequest: GetSecretValueInput = .init(secretId: githubCredentials_secretArn)
		async let githubCredentials_secretResponse = secretsManagerClient.getSecretValue(input: githubCredentials_secretRequest)

		guard let slackCredentials_secretArn = Lambda.env("SLACK_CREDENTIALS_SECRET_ARN") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "SLACK_CREDENTIALS_SECRET_ARN")
		}
		let slackCredentials_secretRequest: GetSecretValueInput = .init(secretId: slackCredentials_secretArn)
		async let slackCredentials_secretResponse = secretsManagerClient.getSecretValue(input: slackCredentials_secretRequest)

		guard let githubSlackConfiguration_secretArn = Lambda.env("GITHUB_SLACK_CONFIGURATION_SECRET_ARN") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "GITHUB_SLACK_CONFIGURATION_SECRET_ARN")
		}
		let githubSlackConfiguration_secretRequest: GetSecretValueInput = .init(secretId: githubSlackConfiguration_secretArn)
		async let githubSlackConfiguration_secretResponse = secretsManagerClient.getSecretValue(input: githubSlackConfiguration_secretRequest)


		guard let githubInstallationLogin = Lambda.env("GITHUB_APP_INSTALLATION_LOGIN") else {
			throw LambdaInitializationError.environmentVariableNotFound(variable: "GITHUB_APP_INSTALLATION_LOGIN")
		}


		// Use a single decoder for all the decoding below, for performance.
		let decoder: JSONDecoder = .init()

		/*
		Wait on and decode secret values fetched from AWS Secrets Manager.
		*/
		guard let githubCredentials_string = try await githubCredentials_secretResponse.secretString else {
			throw LambdaInitializationError.secretNil(description: "Github credentials", arn: githubCredentials_secretArn)
		}
		guard let githubCredentials_data = githubCredentials_string.data(using: .utf8) else {
			throw LambdaInitializationError.secretNotUtf8(description: "Github credentials", arn: githubCredentials_secretArn)
		}
		let githubCredentials = try decoder.decode(GithubCredentials.self, from: githubCredentials_data)

		guard let slackCredentials_string = try await slackCredentials_secretResponse.secretString else {
			throw LambdaInitializationError.secretNil(description: "Slack credentials", arn: slackCredentials_secretArn)
		}
		guard let slackCredentials_data = slackCredentials_string.data(using: .utf8) else {
			throw LambdaInitializationError.secretNotUtf8(description: "Slack credentials", arn: slackCredentials_secretArn)
		}
		let slackCredentials = try decoder.decode(SlackCredentials.self, from: slackCredentials_data)

		guard let githubSlackConfiguration_string = try await githubSlackConfiguration_secretResponse.secretString else {
			throw LambdaInitializationError.secretNil(description: "GitHub/Slack configuration", arn: githubSlackConfiguration_secretArn)
		}
		guard let githubSlackConfiguration_data = githubSlackConfiguration_string.data(using: .utf8) else {
			throw LambdaInitializationError.secretNotUtf8(description: "GitHub/Slack configuration", arn: githubSlackConfiguration_secretArn)
		}
		let githubSlackConfiguration = try decoder.decode(GithubSlackConfiguration.self, from: githubSlackConfiguration_data)


		// With all the required secrets assembled, initialize the GitHub/Slack client.
		self.notifier = try await .init(
			githubAppId: githubCredentials.appId,
			githubPrivateKey: githubCredentials.privateKey,
			githubInstallationLogin: githubInstallationLogin,
			slackAuthToken: slackCredentials.botToken,
			slackChannelId: githubSlackConfiguration.slackChannelId
		)


		self.githubProjectId = githubSlackConfiguration.githubProjectId
		self.githubProjectFieldId = githubSlackConfiguration.githubProjectFieldId
	}


	typealias Event  = FunctionURLRequest
	typealias Output = FunctionURLResponse

	func handle(_ event: Event, context: LambdaContext) async throws -> Output {
		// This should always have a payload, or we have nothing to process.
		guard let payload_string = event.body else {
			context.logger.error("Payload has no body")
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

		let payload: GithubProjectsWebhookRequest
		do {
			payload = try JSONDecoder().decode(GithubProjectsWebhookRequest.self, from: payload_data)
		}
		catch {
			context.logger.error("Payload body could not be decoded to the expected type")
			return .init(statusCode: .badRequest)
		}

		// Only process events that match what we're looking for.
		guard
			payload.action    == "edited",
			payload.projectId == self.githubProjectId,
			let fieldId = payload.fieldId,
			fieldId   == self.githubProjectFieldId
		else {
			context.logger.info("Skipping event with action '\(payload.action)', Project ID '\(payload.projectId)', Field ID '\(String(describing: payload.fieldId))'")
			return .init(statusCode: .noContent)
		}


		context.logger.info("Processing item: \(payload.itemId)")
		let _ = try await self.notifier.sendChangeMessage(itemId: payload.itemId, username: payload.username)

		return .init(statusCode: .noContent)
	}
}
