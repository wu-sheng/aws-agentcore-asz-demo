"""Export one-minute ECS metrics for the independent PoC, without filling gaps."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path

import boto3
from botocore.config import Config


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--start", required=True, help="ISO 8601 UTC timestamp")
    parser.add_argument("--end", help="ISO 8601 UTC timestamp; defaults to now")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    start = datetime.fromisoformat(args.start.replace("Z", "+00:00"))
    end = datetime.fromisoformat(args.end.replace("Z", "+00:00")) if args.end else datetime.now(timezone.utc)
    if not start.tzinfo or not end.tzinfo:
        raise ValueError("timestamps must include a timezone")
    client = boto3.client("cloudwatch", region_name="us-east-1", config=Config(
        retries={"mode": "adaptive", "total_max_attempts": 3}))
    dimensions = [{"Name": "ClusterName", "Value": "asz-pull-judge-cluster"},
                  {"Name": "ServiceName", "Value": "asz-pull-judge-asz"}]
    series = []
    for namespace, names in [("AWS/ECS", ["CPUUtilization", "MemoryUtilization"]),
                             ("ECS/ContainerInsights", ["CpuUtilized", "MemoryUtilized", "NetworkRxBytes", "NetworkTxBytes"])]:
        for name in names:
            result = client.get_metric_statistics(Namespace=namespace, MetricName=name,
                Dimensions=dimensions, StartTime=start, EndTime=end, Period=60,
                Statistics=["Average", "Maximum", "Minimum", "SampleCount"])
            series.append({"namespace": namespace, "metric": name, "dimensions": dimensions,
                           "datapoints": sorted(result["Datapoints"], key=lambda p: p["Timestamp"])})
    args.output.write_text(json.dumps({"start": start, "end": end, "period_seconds": 60,
        "note": "Empty points mean unavailable, not zero. Network metrics are rates; preserve returned units.",
        "series": series}, indent=2, default=str) + "\n")
    print("Metric points saved:", sum(len(row["datapoints"]) for row in series))


if __name__ == "__main__":
    main()
