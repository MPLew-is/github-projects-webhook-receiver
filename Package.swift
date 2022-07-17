// swift-tools-version:5.6

import PackageDescription

let package = Package(
	name: "github-projects-slack-notifications",
	platforms: [
		.macOS(.v12),
	],
	products: [
		.library(
			name: "GithubProjectsSlackNotifier",
			targets: ["GithubProjectsSlackNotifier"]
		),
		.executable(
			name: "GithubProjectsSlackNotifierLambda",
			targets: ["GithubProjectsSlackNotifierLambda"]
		),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-crypto", from: "2.1.0"),
		.package(url: "https://github.com/swift-server/async-http-client", from: "1.11.0"),
		// This is a temporary solution until [the corresponding pull request](https://github.com/swift-server/swift-aws-lambda-events/pull/21) gets upstreamed.
		.package(url: "https://github.com/MPLew-is/swift-aws-lambda-events", branch: "function-url"),
		.package(url: "https://github.com/swift-server/swift-aws-lambda-runtime", revision: "cb340de265665e23984b1f5de3ac4d413a337804"),
		.package(url: "https://github.com/awslabs/aws-sdk-swift", from: "0.2.5"),
		.package(url: "https://github.com/attaswift/BigInt", from: "5.3.0"),
		.package(url: "https://github.com/MPLew-is/deep-codable", branch: "main"),
		.package(url: "https://github.com/MPLew-is/github-graphql-client", branch: "main"),
		.package(url: "https://github.com/MPLew-is/slack-message-client", branch: "main"),
	],
	targets: [
		.target(
			name: "GithubProjectsSlackNotifier",
			dependencies: [
				.product(name: "AsyncHTTPClient",        package: "async-http-client"),
				.product(name: "GithubGraphqlClient",    package: "github-graphql-client"),
				.product(name: "GithubGraphqlQueryable", package: "github-graphql-client"),
				.product(name: "BlockKitMessage",        package: "slack-message-client"),
				.product(name: "SlackMessageClient",     package: "slack-message-client"),
			]
		),
		.executableTarget(
			name: "GithubProjectsSlackNotifierLambda",
			dependencies: [
				"GithubProjectsSlackNotifier",
				.product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
				.product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
				.product(name: "AWSSecretsManager", package: "aws-sdk-swift"),
				.product(name: "BigInt", package: "BigInt"),
				.product(name: "Crypto", package: "swift-crypto"),
				.product(name: "DeepCodable", package: "deep-codable"),
			]
		),
		.executableTarget(
			name: "GenerateHmacSecret",
			dependencies: [
				.product(name: "BigInt", package: "BigInt"),
			]
		),
	]
)
