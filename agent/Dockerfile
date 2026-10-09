# AgentCore Runtime requires an ARM64 (linux/arm64) image pushed to ECR.
# Build with:  docker buildx build --platform linux/arm64 -t <ecr-uri>:<tag> --push .
FROM --platform=linux/arm64 python:3.12-slim

WORKDIR /app

# Install deps first for layer caching.
COPY pyproject.toml ./
RUN pip install --no-cache-dir \
    "langgraph>=0.2.0" \
    "langchain>=0.3.0" \
    "langchain-core>=0.3.0" \
    "langsmith>=0.1.0" \
    "bedrock-agentcore>=0.1.0" \
    "langchain-aws>=0.2.0"

COPY app.py ./

# AgentCore invokes the container over HTTP (/invocations + /ping).
# The SDK's app.run() binds the server; --serve wires that up.
EXPOSE 8080
CMD ["python", "app.py", "--serve"]
