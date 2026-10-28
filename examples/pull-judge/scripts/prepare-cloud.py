"""Prepare local TLS files and isolated tfvars. Does not create AWS resources."""
import argparse
import ipaddress
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--client-ip", required=True)
    parser.add_argument("--region", default="us-east-1")
    args = parser.parse_args()
    address = ipaddress.ip_address(args.client_ip)
    if address.version != 4:
        parser.error("use the client public IPv4 address")
    if args.region != "us-east-1":
        parser.error("this measured PoC currently prepares us-east-1; adapt AZ/model ARNs before another region")
    work = ROOT / ".work/cloud"
    work.mkdir(parents=True, exist_ok=True, mode=0o700)
    config = ROOT / "infra/terraform.tfvars"
    if config.exists():
        raise SystemExit("terraform.tfvars already exists; inspect it instead of overwriting deployment configuration")
    openssl = work / "openssl.cnf"
    openssl.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
                      "[dn]\nCN=asz-pull-judge.internal\n[ext]\nsubjectAltName=DNS:asz-pull-judge.internal\n"
                      "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n"
                      "extendedKeyUsage=serverAuth\n")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "7",
                    "-config", str(openssl), "-keyout", str(work / "key.pem"),
                    "-out", str(work / "cert.pem")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (work / "key.pem").chmod(0o600)
    config.write_text(f'''aws_region = "{args.region}"
project_name = "asz-pull-judge"
asz_ui_cidrs = ["{address}/32"]
availability_zone_ids = ["use1-az1", "use1-az2"]
agent_idle_session_timeout = 1800
tls_cert_file = "{work / 'cert.pem'}"
tls_key_file = "{work / 'key.pem'}"
''')
    config.chmod(0o600)
    print("Prepared isolated tfvars and a 7-day experiment certificate. No AWS resources created.")


if __name__ == "__main__":
    main()
