ARG ASZ_COMMIT=341f8c0c9cb8245669cbe45ff5393f6972e05616
FROM --platform=$BUILDPLATFORM golang:1.27-bookworm AS recorder
ARG ASZ_COMMIT
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
RUN curl -fsSL --retry 3 "https://github.com/apache/skywalking-ai-sessionizer/archive/${ASZ_COMMIT}.tar.gz" | tar -xz --strip-components=1
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -o /out/asz-changes ./plugins/claude-code

FROM python:3.12-slim
ARG ASZ_COMMIT
LABEL io.github.wu-sheng.asz-commit=$ASZ_COMMIT
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY --from=recorder /out/asz-changes /usr/local/bin/asz-changes
COPY --from=recorder /src/plugins/langchain /tmp/asz-langchain
RUN pip install --no-cache-dir /tmp/asz-langchain && asz-langchain enable && rm -rf /tmp/asz-langchain
COPY app.py business.py entrypoint.py ./
RUN useradd -m -u 1000 agent
USER agent
EXPOSE 8080
CMD ["python", "entrypoint.py"]
