# AgentCore Runtime requires a linux/arm64 image in ECR. scripts/up.sh builds
# and pushes it:  docker buildx build --platform linux/arm64 -t <ecr-uri>:<tag> --push .
FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1

# Install deps first for layer caching.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py ./

RUN useradd -m -u 1000 agent
USER agent

# AgentCore invokes the container over HTTP (/invocations + /ping) on 8080.
# With no flag, app.py serves.
EXPOSE 8080
CMD ["python", "app.py"]
