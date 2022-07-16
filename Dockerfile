# syntax=docker/dockerfile:1

# Define common arguments here so they can be used in both `FROM` blocks below.
ARG BUILD_PRODUCT=GithubProjectsSlackNotifierLambda
ARG BUILD_CONFIGURATION=debug
ARG WORKING_DIRECTORY="/${BUILD_PRODUCT}"
ARG LAMBDA_OUTPUT_DIRECTORY="${WORKING_DIRECTORY}/.lambda"
ARG LAMBDA_ZIP_FILENAME="${BUILD_PRODUCT}.zip"


FROM swift:5.6-amazonlinux2 as builder

# Install some extra dependencies needed
RUN \
	yum update --assumeyes && \
	yum install --assumeyes \
		openssl-devel \
		zip

ARG WORKING_DIRECTORY
WORKDIR "${WORKING_DIRECTORY}"

COPY Package.swift Package.resolved ./

COPY Sources Sources

ARG BUILD_PRODUCT
ARG BUILD_CONFIGURATION
ARG LAMBDA_OUTPUT_DIRECTORY
ARG LAMBDA_ZIP_FILENAME

ENV BUILD_CONFIGURATION="${BUILD_CONFIGURATION}"
ENV BUILD_PRODUCT="${BUILD_PRODUCT}"
ENV BUILD_PRODUCT_DIRECTORY=".build/${BUILD_CONFIGURATION}"
ENV LAMBDA_ZIP_DIRECTORY="${LAMBDA_OUTPUT_DIRECTORY}/${BUILD_CONFIGURATION}"
ENV LAMBDA_ZIP_FILENAME="${LAMBDA_ZIP_FILENAME}"
ENV LAMBDA_ZIP_PATH="${LAMBDA_ZIP_DIRECTORY}/${LAMBDA_ZIP_FILENAME}"
ENV LAMBDA_STAGING_DIRECTORY="${LAMBDA_ZIP_DIRECTORY}/${BUILD_PRODUCT}"

# Compile the Swift package with a mounted build cache.
RUN \
	--mount=type=cache,id="swift-build-${BUILD_PRODUCT}",sharing=locked,target="${WORKING_DIRECTORY}/.build" \
		swift build \
			--product "${BUILD_PRODUCT}" \
			--configuration "${BUILD_CONFIGURATION}"

# Zip up the built package into the format needed by AWS.
RUN \
	--mount=type=cache,id="swift-build-${BUILD_PRODUCT}",sharing=locked,target="${WORKING_DIRECTORY}/.build" \
		rm -rf "${LAMBDA_STAGING_DIRECTORY}" && \
		rm -f "${LAMBDA_ZIP_PATH}" && \
		mkdir -p "${LAMBDA_STAGING_DIRECTORY}" && \
		cp "${BUILD_PRODUCT_DIRECTORY}/${BUILD_PRODUCT}" "${LAMBDA_STAGING_DIRECTORY}" && \
		ldd "${BUILD_PRODUCT_DIRECTORY}/${BUILD_PRODUCT}" | grep swift | awk '{print $3}' | xargs cp -L -t "${LAMBDA_STAGING_DIRECTORY}" && \
		ln -s "${BUILD_PRODUCT}" "${LAMBDA_STAGING_DIRECTORY}/bootstrap" && \
		(cd "${LAMBDA_STAGING_DIRECTORY}" && zip --symlinks -r "../${LAMBDA_ZIP_FILENAME}" *)


FROM scratch as output

ARG LAMBDA_OUTPUT_DIRECTORY
ARG BUILD_CONFIGURATION
ARG BUILD_PRODUCT
ARG LAMBDA_ZIP_FILENAME

# Copy the built Lambda Zip over to a blank image so it can be copied back down to the host.
COPY --from=builder \
	"${LAMBDA_OUTPUT_DIRECTORY}/${BUILD_CONFIGURATION}/${LAMBDA_ZIP_FILENAME}" "/${BUILD_CONFIGURATION}/"
