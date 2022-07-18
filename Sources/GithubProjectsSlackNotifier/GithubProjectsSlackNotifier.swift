import AsyncHTTPClient
import BlockKitMessage
import GithubApiClient
import GithubGraphqlQueryable
import SlackMessageClient


/**
Client that reads data about GitHub Projects items and sends corresponding Slack messages.

This must be a `class` to provide `deinit` capabilities to shut down the embedded `AsyncHTTPClient` instance.
*/
public class GithubProjectsSlackNotifier {
	/// Stored async HTTP client object, either auto-created or input by the user
	private let httpClient: HTTPClient
	/// Whether this wrapper should shut down the HTTP client on `deinit`
	private let shouldShutdownHttpClient: Bool

	/// Stored GitHub GraphQL client
	private let githubClient: GithubApiClient

	/// Stored Slack message client
	private let slackClient: SlackMessageClient
	/// Slack channel ID to send messages to
	private let slackChannelId: String


	/**
	Initialize an instance from required configuration parameters.

	- Parameters:
		- githubAppId: unique ID for the GitHub App this client is authenticating as an installation of
		- githubPrivateKey: PEM-encoded private key of the GitHub App, to authenticate as the app to the GitHub API
		- slackAuthToken: Slack API authentication token to use to send messages
		- slackChannelId: Slack channel to send update messages to
		- httpClient: if not provided, the instance will create a new one and destroy it on `deinit`

	- Throws: Only rethrows errors from underlying client initializations
	*/
	public init(
		githubAppId: String,
		githubPrivateKey: String,
		slackAuthToken: String,
		slackChannelId: String,
		httpClient: HTTPClient? = nil
	) async throws {
		if let httpClient = httpClient {
			self.httpClient = httpClient
			self.shouldShutdownHttpClient = false
		}
		else {
			self.httpClient = .init(eventLoopGroupProvider: .createNew)
			self.shouldShutdownHttpClient = true
		}

		self.githubClient = try .init(appId: githubAppId, privateKey: githubPrivateKey, httpClient: self.httpClient)

		self.slackClient = .init(authToken: slackAuthToken, httpClient: self.httpClient)
		self.slackChannelId = slackChannelId
	}

	/// If this instance created its own HTTP client, shut it down.
	deinit {
		if self.shouldShutdownHttpClient {
			try? httpClient.syncShutdown()
		}
	}


	/// Object representing selected fields and child objects of a GitHub Projects (V2) item
	internal struct ProjectItem: GithubGraphqlQueryable {
		/// Object representing selected fields and child objects of a GitHub Projects (V2) project
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

		/// Object representing selected fields and child objects of a GitHub Projects (V2) field
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

		/// The value of the "Status" field attached to this item, fetched from the contained field-value list
		internal var status: String? {
			let statusField = fieldValues.first { $0.fieldName == "Status" }
			return statusField?.value
		}
	}

	/**
	Send a Slack message about the input GitHub Project item changing statuses.

	- Parameters:
		- itemId: GraphQL node ID for the item that has changed statuses
		- username: GitHub username that initiated the change action
		- installationId: GitHub App installation ID this request is being executed on behalf of

	- Returns: `true` if a message was sent, `false` otherwise (items are ignored if they have no status)
	- Throws: Only rethrows errors from underlying GraphQL querying or Slack message sending
	*/
	public func sendChangeMessage(itemId: String, username: String, installationId: Int) async throws -> Bool {
		let item = try await self.githubClient.graphqlQuery(ProjectItem.self, id: itemId, for: installationId)
		let project = item.project

		guard let status = item.status else {
			return false
		}


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

		return true
	}
}
