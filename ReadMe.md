# GitHub Projects (V2) Webhook Receiver #

This repository provides an AWS Lambda to:
1. Send a Slack message when a GitHub Projects (V2) item changes statuses
2. Watch issue comments for a `/status` command to schedule a status change on a specific date

Roughly, the following steps are performed when a webhook event is received:

- If the event was a `projects_v2_item` event:
	1. If the event matches the watched project/field, query the GitHub API for information about the item
	2. Construct and send a Slack message to a specified channel with information from above steps

- If the event was an `issue_comment` event:
	1. Check for the first word being `/status`, skipping the event otherwise
	2. Check for the next word being `cancel`, removing any already-scheduled moves from DynamoDB
	3. Parse the remaining words as `{status} on {date}` or `{status} in {number} {interval}`, storing the corresponding status move in DynamoDB

This is built upon the following packages, see those repositories for more in-depth information:
- [GitHub GraphQL client](https://github.com/MPLew-is/github-graphql-client)
- [Slack Message client](https://github.com/MPLew-is/slack-message-client)

**Important**: this is still in extremely early development, and the below setup steps are mostly to document my own deployment of this Lambda rather than be a guarantee of how to set this up from scratch.


## Setup ##

1. Copy the directory `Example secrets` to `Secrets`

### GitHub ###

1. [Create a GitHub App](https://docs.github.com/en/developers/apps/building-github-apps/creating-a-github-app) in your account (alternatively use an existing app you have already created)
	- The only values you need to fill in are the app name and URL (which can be your GitHub profile URL), and you can uncheck `Active` under `Webhook` (you'll come back and fill this in once you have a URL)
	- Under `Repository permissions`, then `Issues`, grant `Read and write` permissions
	- Under `Organization permissions`, then `Projects`, grant `Read and write` permissions
2. After successful creation, copy the `App ID` value and replace the example value for the key `appId` in `Secrets/github-credentials.json`
3. At the bottom of the same page, under `Private keys`, generate a private key for your app
4. Open the generated and downloaded `.pem` file in a text editor, copy the entire contents, and replace the example value for the key `privateKey` in `Secrets/github-credentials.json`
	- **Important**: make sure you replace all new lines in the `.pem` with `\n` as in the example value
5. [Create a new example project](https://docs.github.com/en/issues/trying-out-the-new-projects-experience/quickstart#creating-a-project) (alternatively reuse an existing project you have already created)
	- **Important**: make note of the project number (`{number`} in `https://github.com/orgs/{organization}/projects/{number}` from the project's URL)
6. [Create a new repository](https://github.com/new) to contain issues for the project (alternatively reuse an existing repository you have already created)
7. Copy the name of your new repository (in `{Username}/{Repository}` format) and replace the example value for the key `githubRepository` in `Secrets/lambda-configuration.json`
8. [Install your new app on the account containing the new project](https://docs.github.com/en/developers/apps/managing-github-apps/installing-github-apps#installing-your-private-github-app-on-your-repository), granting access to the issue-containing repository
9.  [Install and set up the GitHub CLI tool](https://cli.github.com/manual/)
	- On macOS with Homebrew installed, you can just run:
		1. `brew install gh`
		2. `gh auth login`
10. Query the GraphQL API for the required project and field IDs to watch (making sure to replace example values):
	```sh
	gh api graphql --field organizationLogin='{Your organization username}' --field projectNumber='{Your project number}' --raw-field query='
		query($organizationLogin: String!, $projectNumber: Int!) {
			organization(login: $organizationLogin) {
				projectV2(number: $projectNumber) {
					id
					field(name: "Status") {
						... on ProjectV2SingleSelectField {
							id
						}
					}
				}
			}
		}
	'
	```
11. Copy the value at `data.organization.projectV2.id` and replace the example value for the key `githubProjectId` in `Secrets/lambda-configuration.json`
12. Copy the `data.organization.projectV2.field.id`, then replace the example value for the key `githubProjectFieldId` in `Secrets/lambda-configuration.json`
13. [Create an HMAC secret for your webhook](https://docs.github.com/en/developers/webhooks-and-events/webhooks/securing-your-webhooks#setting-your-secret-token), copy it, and replace the example value for the key `webhookSecret` in `Secrets/github-credentials.json`
	- An example tool has been provided in this package to generate a sufficiently secure secret, simply run: `swift run GenerateHmacSecret` and copy the resulting output string


### Slack ###

1. [Create a Slack App](https://api.slack.com/apps) for your workspace (alternatively use an existing app you have already created and installed)
2. Add the [`chat.write`](https://api.slack.com/scopes/chat:write) bot scope under **OAuth & Permissions**
3. Install the app to your workspace
4. Copy the app's Bot Token from the **OAuth & Permissions** page and replace the example value for the key `botToken` in `Secrets/slack-credentials.json`
5. Invite the bot user into the channel you wish to post messages to (`/invite @bot_user_name`).
6. Click the channel name in the upper bar, then copy the channel ID from the resulting screen and replace the example value for the key `slackChannelId` in `Secrets/lambda-configuration.json`


### AWS ###

1. [Create 3 AWS Secrets Manager secrets](https://docs.aws.amazon.com/secretsmanager/latest/userguide/hardcoded.html) for each of the JSON files in `Secrets`, setting the secret value to the entire contents of the file
	- Naming does not matter here, but the following is recommended:
		- `github-credentials.json`: `githubCredentials`
		- `slack-credentials.json`: `slackCredentials`
		- `lambda-configuration.json`: `webhookReceiverConfiguration`
	- Copy the ARNs of all 3 for use in a later step
2. [Create an AWS DynamoDB table](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/getting-started-step-1.html) with partition key `itemId` of type `String`
	- Naming does not matter, but `scheduledProjectItemMoves` is recommended
3. [Create a Global Secondary index on your DynamoDB table](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/getting-started-step-6.html) with partition key `projectId` of type `String` and sort key `scheduledDate` of type `String`
	- Naming does not matter, but `itemsByDate` is recommended
4. Install `Docker`
	- On macOS with Homebrew installed, you can just run:
		1. `brew install --cask docker`
		2. Launch and set up `Docker.app` (default settings are fine)
5. Create the directory for the output Lambda: `mkdir .lamdba`
6. Build the Lambda in a container, and copy the resulting Zip to your host: `DOCKER_BUILDKIT=1 docker build --output .lambda`
7. [Create an AWS Lambda](https://docs.aws.amazon.com/lambda/latest/dg/getting-started.html) and upload the Zip file at `.lambda/debug/GithubProjectsWebhookReceiver.zip` as the deployment package
	- You will need to [grant the Lambda permissions](https://docs.aws.amazon.com/lambda/latest/dg/lambda-permissions.html) to the Secrets and DynamoDB table created above
8. [Set environment variables for the Lambda](https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html) to function correctly:
	- `REGION`: AWS region name in which you've deployed the Lambda and secrets (for example, `us-west-1`)
	- `GITHUB_CREDENTIALS_SECRET_ARN`: ARN for the GitHub credentials secret created above
	- `SLACK_CREDENTIALS_SECRET_ARN`: ARN for the Slack credentials secret created above
	- `CONFIGURATION_SECRET_ARN`: ARN for the configuration secret created above
	- `SCHEDULED_MOVES_TABLE_NAME`: name of the DynamoDB table created above
9. [Create a Function URL](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html) for your Lambda
10. Back in your GitHub App settings, in the `General` tab and the `Webhook` section, check the `Active` box and fill in your new Lambda URL
	- Use the HMAC secret created above and stored in `Secrets/github-credentials.json` as the Webhook secret
	- Make sure to click `Save changes` when done
11. In the `Permissions & events` tab, under the `Subscribe to events` section, select `Projects v2 item` and `Issue comments` and then click `Save changes`

You should now be able to:
- Create/move items in your project and have a Slack notification sent to your specified channel
- Reply to an issue with a comment like `/status To-do in 2 weeks` and have a corresponding move inserted into your DynamoDB table
