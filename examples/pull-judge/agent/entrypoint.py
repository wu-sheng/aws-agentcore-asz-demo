"""Fetch the ingestion credential using the runtime role before importing the agent."""
import os

import boto3
from botocore.config import Config


def main():
    secret_arn = os.environ.get("INGEST_SECRET_ARN")
    if secret_arn:
        client = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "us-east-1"),
                              config=Config(retries={"mode": "adaptive", "total_max_attempts": 3}))
        os.environ["LANGSMITH_API_KEY"] = client.get_secret_value(SecretId=secret_arn)["SecretString"]
    from app import main as serve
    serve()


if __name__ == "__main__":
    main()
