import Foundation

import AWSDynamoDB
import AWSLambdaRuntime
import AsyncHTTPClient
import DeepCodable
import GithubGraphqlQueryable
import NIOFoundationCompat


/// Data received in a GitHub `issue_comment` webhook request
fileprivate struct IssueCommentEvent: DeepDecodable {
	static let codingTree = CodingTree {
		Key("action", containing: \._action)

		Key("issue") {
			Key("node_id", containing: \._issueId)
			Key("comments_url", containing: \._issueCommentsUrl)
		}

		Key("comment") {
			Key("body", containing: \._commentBody)

			Key("reactions") {
				Key("url", containing: \._commentReactionsUrl)
			}
		}

		Key("repository") {
			Key("full_name", containing: \._repositoryName)
		}

		Key("sender") {
			Key("login", containing: \._username)
		}
	}

	/// Action this event is informing us about (`edited`, `created`, `reordered`, etc.)
	@Value var action: String
	/// Username performing the action
	@Value var username: String

	/// API URL at which to view or modify reactions
	@Value var commentReactionsUrl: String
	/// Text body of the issue comment
	@Value var commentBody: String

	/// Unique ID of the issue containing this comment (GraphQL node ID)
	@Value var issueId: String
	/// API URL for interacting with comments on this issue
	@Value var issueCommentsUrl: String

	/// Name of GitHub repository containing this issue
	@Value var repositoryName: String
}


/// Selected fields and child objects of a GitHub Issue
struct Issue: GithubGraphqlQueryable {
	/// Selected fields and child objects of a GitHub Projects (V2) project
	struct ProjectItem: GithubGraphqlQueryable {
		/// Selected fields and child objects of a GitHub Projects (V2) field
		struct ProjectField: GithubGraphqlQueryable {
			/// Selected fields for a GitHub Projects (V2) single-select field (like board columns)
			struct Option: GithubGraphqlQueryable {
				static let query = Node(type: "ProjectV2SingleSelectFieldOption") {
					Field("id", containing: \._id)
					Field("name", containing: \._name)
				}

				/// Unique ID for this field option (*not* a GraphQL node ID)
				@Value var id: String
				/// Human-readable name for this field option
				@Value var name: String
			}

			static let query = Node(type: "ProjectV2SingleSelectField") {
				Field("id", containing: \._id)

				Field("options", containing: \._options)
			}

			/// Unique ID for this single-select field (GraphQL node ID)
			@Value var id: String
			/// Possible options for the value of this field
			@Value var options: [Option]
		}

		static let query = Node(type: "ProjectV2Item") {
			Field("id", containing: \._id)

			Field("project") {
				Field("id", containing: \._projectId)

				FilteredField("field", name: "Status", containing: \._statusField)
			}
		}


		/// Unique ID for this project item (GraphQL node ID)
		@Value var id: String
		/// Unique ID for the project containing this item (GraphQL node ID)
		@Value var projectId: String

		/// Field of this project named "Status", if present
		@Value var statusField: ProjectField?
	}

	static let query = Node(type: "Issue") {
		Field("id", containing: \._id)

		FieldList("projectItems", first: 10, containing: \._projectItems)
	}


	/// Unique ID for this issue (GraphQL node ID)
	@Value var id: String
	/// Project items associated with this issue
	@Value var projectItems: [ProjectItem]
}


/// Shortcut type alias for a DynamoDB attribute value
typealias DynamoDbValue = DynamoDbClientTypes.AttributeValue

extension FunctionUrlLambdaHandler {
	/**
	Watched command string, for centralization purposes

	We can't add a stored property on an extension, so just use a computed one here.
	*/
	static var commandString: String { "/status" }

	/**
	Process the input `projects_v2_item` webhook event, sending a Slack message about the item changing statuses if it matches the watched configuration.

	- Parameters:
		- payload: bytes of the JSON payload of the webhook event
		- context: Lambda invocation context, to access things like the Lambda's logger
		- installationId: GitHub App installation ID this request is being executed on behalf of

	- Returns: An HTTP response object matching the type of the root `handle` function
	- Throws: Only rethrows errors from underlying GraphQL querying or Slack message sending
	*/
	func handleIssueComment(payload payload_data: Data, context: LambdaContext, installationId: Int) async throws -> Output {
		guard let scheduledMovesTableName = Lambda.env("SCHEDULED_MOVES_TABLE_NAME") else {
			context.logger.critical("No DynamoDB table name found for scheduled moves table from environment variable: SCHEDULED_MOVES_TABLE_NAME")
			return .init(statusCode: .internalServerError)
		}

		let payload: IssueCommentEvent
		do {
			payload = try JSONDecoder().decode(IssueCommentEvent.self, from: payload_data)
		}
		catch {
			context.logger.error("Payload body could not be decoded to the expected type")
			return .init(statusCode: .badRequest)
		}

		// Only watch for new comments, not edited ones or any other actions.
		guard payload.action == "created" else {
			context.logger.info("Skipping comment not matching action 'created': \(payload.action)")
			return .init(statusCode: .noContent)
		}

		guard payload.repositoryName == self.githubRepository else {
			context.logger.info("Skipping comment not matching repository '\(self.githubRepository)': \(payload.repositoryName)")
			return .init(statusCode: .noContent)
		}

		// Pre-lowercase all the words in the comment here so all our matching is case-insensitive.
		let commentWords = payload.commentBody.lowercased().split(separator: " ")
		guard let firstWord = commentWords.first else {
			context.logger.info("Skipping empty comment body")
			return .init(statusCode: .noContent)
		}
		guard firstWord == Self.commandString else {
			context.logger.info("Skipping event with first word not matching expected '\(Self.commandString)': \(firstWord)")
			return .init(statusCode: .noContent)
		}
		var remainingWords = commentWords.dropFirst()
		context.logger.info("Successfully parsed command string, remaining words: \(remainingWords.joined(separator: " "))")


		let issue = try await self.githubClient.graphqlQuery(Issue.self, id: payload.issueId, for: installationId)
		guard let projectItem = issue.projectItems.first(where: { $0.projectId == self.githubProjectId }) else {
			context.logger.info("Issue not part of project '\(self.githubProjectId)': \(issue.id)")
			return try await self.postUsageErrorComment(
				payload: payload,
				comment: "this issue is not part of the project being watched - please add it to the project and try again.",
				installationId: installationId
			)
		}


		if remainingWords.count == 1 && remainingWords.first! == "cancel" {
			context.logger.info("Successfully parsed 'cancel' subcommand, removing item from table: \(projectItem.id)")
			let dynamoDbKey: [String: DynamoDbValue] = [
				"itemId": .s(projectItem.id),
			]
			let _ = try await self.dynamoDbClient.deleteItem(input: .init(key: dynamoDbKey, tableName: scheduledMovesTableName))

			return try await self.reactWithPlusOne(payload: payload, installationId: installationId)
		}


		guard remainingWords.count >= 3 else {
			context.logger.info("Not enough words remaining: \(remainingWords.joined(separator: " "))")
			return try await self.postCommandParsingErrorComment(payload: payload, installationId: installationId)
		}


		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy-MM-dd"

		let targetDate: Date
		if remainingWords[remainingWords.endIndex - 2] == "on" {
			let date_string = String(remainingWords.last!)
			guard let date = dateFormatter.date(from: date_string) else {
				context.logger.info("Could not parse date: \(date_string)")
				return try await self.postUsageErrorComment(
					payload: payload,
					comment: "`\(date_string)` could not be parsed as a date in `YYYY-MM-DD` format - please try again.",
					installationId: installationId
				)
			}

			remainingWords = remainingWords.dropLast(2)
			targetDate = date
		}
		else if remainingWords[remainingWords.endIndex - 3] == "in" {
			let value_string = remainingWords[remainingWords.endIndex - 2]
			guard let value = Double(value_string) else {
				context.logger.info("Could not parse numerical value: \(value_string)")
				return try await self.postUsageErrorComment(
					payload: payload,
					comment: "`\(value_string)` could not be parsed as an integer - please try again.",
					installationId: installationId
				)
			}
			guard value > 0 else {
				context.logger.info("Numerical value was negative: \(value_string)")
				return try await self.postUsageErrorComment(
					payload: payload,
					comment: "`\(value_string)` must be greater than zero - please try again.",
					installationId: installationId
				)
			}

			let unit = remainingWords.last!

			let day_seconds: Double = 24 * 60 * 60
			let week_seconds = 7 * day_seconds
			let month_seconds = 30 * day_seconds

			let now = Date()
			let date: Date
			switch unit {
				case "month", "months":
					date = now + value * month_seconds

				case "week", "weeks":
					date = now + value * week_seconds

				case "day", "days" :
					date = now + value * day_seconds

				default:
					context.logger.info("Unit was not days, weeks, or months: \(unit)")
					return try await self.postUsageErrorComment(
						payload: payload,
						comment: "`\(unit)` must be one of `day`/`days`, `week`/`weeks`, or `month`/`months` - please try again.",
						installationId: installationId
					)
			}

			remainingWords = remainingWords.dropLast(3)
			targetDate = date
		}
		else {
			context.logger.info("Was not able to parse which scheduling command to use: \(remainingWords.joined(separator: " "))")
			return try await self.postCommandParsingErrorComment(payload: payload, installationId: installationId)
		}


		guard let statusField = projectItem.statusField else {
			context.logger.info("Configured project does not have a 'Status' field: \(projectItem.projectId)")
			return try await self.postUsageErrorComment(
				payload: payload,
				comment: "this project does not have a field named `Status` - please update the project and try again.",
				installationId: installationId
			)
		}

		let targetStatus = remainingWords.joined(separator: " ")
		guard let statusValue = statusField.options.first(where: { $0.name.lowercased() == targetStatus}) else {
			context.logger.info("Configured project does not have a matching status value: \(targetStatus)")
			return try await self.postUsageErrorComment(
				payload: payload,
				comment: "this project does not have a status named `\(targetStatus)` - please try again.",
				installationId: installationId
			)
		}

		context.logger.info("Successfully parsed scheduling subcommand, adding item to table: \(projectItem.id)")
		let dynamoDbItem: [String: DynamoDbValue] = [
			"projectId"      : .s(projectItem.projectId),
			"scheduledDate"  : .s(dateFormatter.string(from: targetDate)),
			"itemId"         : .s(projectItem.id),
			"fieldId"        : .s(statusField.id),
			"fieldValue"     : .s(statusValue.id),
			"fieldValueName" : .s(statusValue.name),
			"installationId" : .n(String(installationId)),
			"username"       : .s(payload.username),
			"commentsUrl"    : .s(payload.issueCommentsUrl),
		]
		let _ = try await self.dynamoDbClient.putItem(input: .init(item: dynamoDbItem, tableName: scheduledMovesTableName))


		return try await self.reactWithPlusOne(payload: payload, installationId: installationId)
	}


	/**
	React to the comment represented by the input payload with a `+1` reaction.

	- Parameters:
		- payload: event received from a GitHub webhook detailing the new issue comment
		- installationId: ID of the GitHub App installation to act on behalf of

	- Returns: An HTTP response object matching the type of the root `handle` function
	- Throws: Only rethrows errors from the underlying encoding/GitHub API interactions
	*/
	fileprivate func reactWithPlusOne(payload: IssueCommentEvent, installationId: Int) async throws -> Output {
		let _ = try await self.githubClient.createIssueCommentReaction(url: payload.commentReactionsUrl, reaction: .plusOne, for: installationId)

		return .init(statusCode: .noContent)
	}

	/**
	Reply to the comment represented by the input payload with a `confused` reaction and post a generic list of how the command can be used.

	- Parameters:
		- payload: event received from a GitHub webhook detailing the new issue comment
		- installationId: ID of the GitHub App installation to act on behalf of

	- Returns: An HTTP response object matching the type of the root `handle` function
	- Throws: Only rethrows errors from the underlying encoding/GitHub API interactions
	*/
	fileprivate func postCommandParsingErrorComment(payload: IssueCommentEvent, installationId: Int) async throws -> Output {
		return try await self.postUsageErrorComment(
			payload: payload,
			comment: """
				you must specify a command in one of the following formats:
				- `\(Self.commandString) {status} on {date}`
				- `\(Self.commandString) {status} in {number} [day(s)|week(s)|month(s)]`
				- `\(Self.commandString) cancel`
				""",
			installationId: installationId
		)
	}


	/**
	Reply to the comment represented by the input payload with a `confused` reaction and the input comment.

	- Parameters:
		- payload: event received from a GitHub webhook detailing the new issue comment
		- comment: new comment body to reply with
		- installationId: ID of the GitHub App installation to act on behalf of

	- Returns: An HTTP response object matching the type of the root `handle` function
	- Throws: Only rethrows errors from the underlying encoding/GitHub API interactions
	*/
	fileprivate func postUsageErrorComment(payload: IssueCommentEvent, comment: String, installationId: Int) async throws -> Output {
		let _ = try await self.githubClient.createIssueCommentReaction(url: payload.commentReactionsUrl, reaction: .confused, for: installationId)
		let _ = try await self.githubClient.createIssueComment(url: payload.issueCommentsUrl, body: "@\(payload.username) \(comment)", for: installationId)

		return .init(statusCode: .noContent)
	}
}
