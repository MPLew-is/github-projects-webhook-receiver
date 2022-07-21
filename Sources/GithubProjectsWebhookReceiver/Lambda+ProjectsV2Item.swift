import Foundation

import AWSLambdaRuntime
import BlockKitMessage
import DeepCodable
import GithubGraphqlQueryable
import SlackMessageClient


/// Data received in a GitHub `projects_v2_item` webhook request
struct ProjectsItemEvent: DeepDecodable {
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


/// Selected fields and child objects of a GitHub Projects (V2) item
internal struct ProjectItem: GithubGraphqlQueryable {
	/// Selected fields of a GitHub Projects (V2) project
	internal struct Project: GithubGraphqlQueryable {
		internal static let query = Node(type: "ProjectV2") {
			Field("title", containing: \._title)
			Field("url", containing: \._url)
		}

		/// GitHub Project number (for instance, `{number}` in: `https://github.com/orgs/{username}/projects/{number}`
		@Value internal var number: Int
		/// GitHub Project name
		@Value internal var title: String
		/// URL to GitHub Project
		@Value internal var url: String
	}

	/// Selected fields and child objects of a GitHub Projects (V2) field
	internal struct ProjectFieldValue: GithubGraphqlQueryable {
		internal static let query = Node(type: "ProjectV2ItemFieldSingleSelectValue") {
			Field("name", containing: \._value)
			Field("field") {
				IfType("ProjectV2FieldCommon") {
					Field("name", containing: \._fieldName)
				}
			}
		}

		/// Name of the field this value is part of (might be `nil` since we're filtering on single-select fields)
		@Value internal var fieldName: String?
		/// Value of the field (might be `nil` since we're filtering on single-select fields)
		@Value internal var value: String?
	}


	internal static let query = Node(type: "ProjectV2Item") {
		Field("content") {
			IfType("DraftIssue") {
				Field("title", containing: \._title)
			}

			IfType("Issue") {
				Field("title", containing: \._title)
				Field("url", containing: \._url)
			}

			IfType("PullRequest") {
				Field("title", containing: \._title)
				Field("url", containing: \._url)
			}
		}

		FieldList("fieldValues", first: 10, containing: \._fieldValues)

		Field("project", containing: \._project)
	}

	/// GitHub Project item title
	@Value internal var title: String
	/// URL to Github Project item (`nil` when the item is a draft issue)
	@Value internal var url: String?
	/// GitHub Project this item is associated with
	@Value internal var project: Project
	/// GitHub Project field values associated with this item
	@Value internal var fieldValues: [ProjectFieldValue]

	/// Value of the "Status" field attached to this item, fetched from the contained field-value list
	internal var status: String? {
		let statusField = fieldValues.first { $0.fieldName == "Status" }
		return statusField?.value
	}
}

extension FunctionUrlLambdaHandler {
	/**
	Process the input `projects_v2_item` webhook event, sending a Slack message about the item changing statuses if it matches the watched configuration.

	- Parameters:
		- payload: bytes of the JSON payload of the webhook event
		- context: Lambda invocation context, to access things like the Lambda's logger
		- installationId: GitHub App installation ID this request is being executed on behalf of

	- Returns: An HTTP response object matching the type of the root `handle` function
	- Throws: Only rethrows errors from underlying GraphQL querying or Slack message sending
	*/
	func handleProjectsItem(payload payload_data: Data, context: LambdaContext, installationId: Int) async throws -> Output {
		let payload: ProjectsItemEvent
		do {
			payload = try JSONDecoder().decode(ProjectsItemEvent.self, from: payload_data)
		}
		catch {
			context.logger.error("Payload body could not be decoded to the expected type")
			return .init(statusCode: .badRequest)
		}

		guard let fieldId = payload.fieldId else {
			context.logger.info("Skipping event with no field ID'")
			return .init(statusCode: .noContent)
		}

		guard
			payload.action    == "edited",
			payload.projectId == self.githubProjectId,
			fieldId           == self.githubProjectFieldId
		else {
			context.logger.info("Skipping event with action '\(payload.action)', Project ID '\(payload.projectId)', Field ID '\(fieldId)'")
			return .init(statusCode: .noContent)
		}


		let itemId = payload.itemId
		context.logger.info("Processing item: \(itemId)")

		let item = try await self.githubClient.graphqlQuery(ProjectItem.self, id: itemId, for: installationId)
		let project = item.project

		guard let status = item.status else {
			context.logger.info("Skipping item without a status value: \(itemId)")
			return .init(statusCode: .noContent)
		}

		let username = payload.username


		let message = Message.build {
			Header("\(item.title) moved to \(status)")

			Section(mrkdwn: "*<\(item.url ?? project.url)|\(item.title)>* moved to status *\(status)* in *<\(project.url)|\(project.title)>*")

			Context.build {
				Image(url: "https://github.com/\(username).png", alternateText: "\(username) profile picture")
				Mrkdwn("Performed by *<https://github.com/\(username)|\(username)>*")
			}
		}

		let text = "'\(item.title)' moved to '\(status)' by \(username)"
		try await self.slackClient.post(message, to: self.slackChannelId, fallback: text)

		return .init(statusCode: .noContent)
	}
}
