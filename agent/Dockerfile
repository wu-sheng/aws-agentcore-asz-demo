# AgentCore Runtime requires a linux/arm64 image in ECR. scripts/up.sh builds
# and pushes it:  docker buildx build --platform linux/arm64 -t <ecr-uri>:<tag> --push .
#
# Besides the agent, the image carries what records which tool changed which
# files: asz-changes, and the LangChain shim that runs it around each tool
# call. Both come from apache/skywalking-ai-sessionizer at ASZ_COMMIT, the
# same commit as the asz image (scripts/up.sh passes it from var.asz_image),
# so the shim files a change under the conversation name asz gives it.
ARG ASZ_COMMIT=8104ada77cbd0d5ca69754d50cbbc0cd6f9bbec5

# asz-changes is pure Go: build it on the build machine for the target.
FROM --platform=$BUILDPLATFORM golang:1.27-bookworm AS asz
ARG ASZ_COMMIT
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
RUN curl -fsSL --retry 5 --retry-all-errors "https://github.com/apache/skywalking-ai-sessionizer/archive/${ASZ_COMMIT}.tar.gz" \
      | tar -xz --strip-components=1
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
      go build -trimpath -ldflags "-s -w" -o /out/asz-changes ./plugins/claude-code

FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1

# git for the clone_demo_repo tool.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Install deps first for layer caching.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# The recorder and the shim. `asz-langchain enable` puts a loader in the site
# directory; it attaches the handler only when ASZ_CHANGES=true.
COPY --from=asz /out/asz-changes /usr/local/bin/asz-changes
COPY --from=asz /src/plugins/langchain /tmp/asz-langchain
RUN pip install --no-cache-dir /tmp/asz-langchain \
 && asz-langchain enable \
 && rm -rf /tmp/asz-langchain

COPY app.py ./

RUN useradd -m -u 1000 agent
USER agent

# AgentCore invokes the container over HTTP (/invocations + /ping) on 8080.
# With no flag, app.py serves.
EXPOSE 8080
CMD ["python", "app.py"]
