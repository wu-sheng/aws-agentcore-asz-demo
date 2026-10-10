# AgentCore Runtime requires a linux/arm64 image in ECR. Only GitHub Actions
# builds and publishes this image (.github/workflows/agent-image.yml, to GHCR);
# scripts/up.sh copies it into the account's ECR. scripts/run-agent-local.sh
# builds it from a checkout for local testing and never pushes it.
#
# Besides the agent, the image carries what records which tool changed which
# files: asz-changes, and the LangChain shim that runs it around each tool
# call. Both come from apache/skywalking-ai-sessionizer at ASZ_COMMIT, the
# same commit as the asz image (the workflow, up.sh and run-agent-local.sh
# pass the pinned commit), so the shim files a change under the conversation
# name asz gives it.
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
ARG ASZ_COMMIT
# up.sh compares this with the asz commit var.asz_image pins.
LABEL io.github.wu-sheng.asz-commit=$ASZ_COMMIT

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
