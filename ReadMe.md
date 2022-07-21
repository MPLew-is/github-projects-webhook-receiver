# GitHub Projects (V2) Webhook Receiver #

This repository provides an AWS Lambda to send a Slack message when a GitHub Projects (V2) item changes statuses.

Roughly, the following steps are performed:

1. Receive a GitHub `projects_v2_item` webhook
2. If the event matches the watched project/field, query the GitHub API for information about the item
3. Construct and send a Slack message to a specified channel with information from above steps

This is built upon the following packages, see those repositories for more in-depth information:
- [GitHub GraphQL client](https://github.com/MPLew-is/github-graphql-client)
- [Slack Message client](https://github.com/MPLew-is/slack-message-client)

**Important**: this is still in extremely early development, and the below setup steps are mostly to document my own deployment of this Lambda rather than be a guarantee of how to set this up from scratch.


## Setup ##

1. Copy the directory `Example secrets` to `Secrets`

### GitHub ###

1. [Create a GitHub App](https://docs.github.com/en/developers/apps/building-github-apps/creating-a-github-app) in your account (alternatively use an existing app you have already created)
	- The only values you need to fill in are the app name and URL (which can be your GitHub profile URL), and you can uncheck `Active` under `Webhook` (you'll come back and fill this in once you have a URL)
	- Under `Repository permissions`, then `Issues`, grant `Read-only` permissions
	- Under `Organization permissions`, then `Projects`, grant `Read-only` permissions
2. After successful creation, copy the `App ID` value and replace the example value for the key `appId` in `Secrets/github-credentials.json`
3. At the bottom of the same page, under `Private keys`, generate a private key for your app
4. Open the generated and downloaded `.pem` file in a text editor, copy the entire contents, and replace the example value for the key `privateKey` in `Secrets/github-credentials.json`
	- **Important**: make sure you replace all new lines in the `.pem` with `\n` as in the example value
5. [Create a new example project](https://docs.github.com/en/issues/trying-out-the-new-projects-experience/quickstart#creating-a-project) (alternatively reuse an existing project you have already created)
	- **Important**: make note of the project number (`{number`} in `https://github.com/orgs/{organization}/projects/{number}` from the project's URL)
6. [Create a new repository](https://github.com/new) to contain issues for the project (alternatively reuse an existing repository you have already created)
7. [Install your new app on the account containing the new project](https://docs.github.com/en/developers/apps/managing-github-apps/installing-github-apps#installing-your-private-github-app-on-your-repository), granting access to the issue-containing repository
8.  [Install and set up the GitHub CLI tool](https://cli.github.com/manual/)
	- On macOS with Homebrew installed, you can just run:
		1. `brew install gh`
		2. `gh auth login`
9. Query the GraphQL API for the required project and field IDs to watch (making sure to replace example values):
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
10. Copy the value at `data.organization.projectV2.id` and replace the example value for the key `githubProjectId` in `Secrets/lambda-configuration.json`
11. Copy the `data.organization.projectV2.field.id`, **delete the `SS` in the ID (replace `PVTSSF` with `PVTF`), then replace the example value for the key `githubProjectFieldId` in `Secrets/lambda-configuration.json`
12. [Create an HMAC secret for your webhook](https://docs.github.com/en/developers/webhooks-and-events/webhooks/securing-your-webhooks#setting-your-secret-token), copy it, and replace the example value for the key `webhookSecret` in `Secrets/github-credentials.json`
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
2. Install `Docker`
	- On macOS with Homebrew installed, you can just run:
		1. `brew install --cask docker`
		2. Launch and set up `Docker.app` (default settings are fine)
3. Create the directory for the output Lambda: `mkdir .lamdba`
4. Build the Lambda in a container, and copy the resulting Zip to your host: `DOCKER_BUILDKIT=1 docker build --output .lambda`
5. [Create an AWS Lambda](https://docs.aws.amazon.com/lambda/latest/dg/getting-started.html) and upload the Zip file at `.lambda/debug/GithubProjectsSlackNotifierLambda.zip` as the deployment package
6. [Set environment variables for the Lambda](https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html) to function correctly:
	- `REGION`: AWS region name in which you've deployed the Lambda and secrets (for example, `us-west-1`)
	- `GITHUB_CREDENTIALS_SECRET_ARN`: ARN for the GitHub credentials secret created above
	- `SLACK_CREDENTIALS_SECRET_ARN`: ARN for the Slack credentials secret created above
	- `CONFIGURATION_SECRET_ARN`: ARN for the GitHub/Slack configuration secret created above
7. [Create a Function URL](https://docs.aws.amazon.com/lambda/latest/dg/urls-configuration.html) for your Lambda
8. Back in your GitHub App settings, in the `General` tab and the `Webhook` section, check the `Active` box and fill in your new Lambda URL
	- Use the HMAC secret created above and stored in `Secrets/github-credentials.json` as the Webhook secret
	- Make sure to click `Save changes` when done
9. In the `Permissions & events` tab, under the `Subscribe to events` section, select `Projects v2 item` and then click `Save changes`

You should now be able to create/move items in your project and have a Slack notification sent to your specified channel.
