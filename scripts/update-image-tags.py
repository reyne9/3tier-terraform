#!/usr/bin/env python3
"""Update the AWS or Azure GitOps manifests after images have been published."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DEPLOYMENTS = {
    "aws": ROOT / "codes/aws/2. service/k8s-manifests",
    "azure": ROOT / "codes/azure/2-emergency/k8s-manifests",
}


def update(target: str, registry_user: str, tag: str) -> None:
    if target not in DEPLOYMENTS:
        raise ValueError("target must be aws or azure")
    if not re.fullmatch(r"[a-z0-9_-]+", registry_user):
        raise ValueError("invalid Docker Hub account")
    if not re.fullmatch(r"[a-zA-Z0-9_.-]+", tag):
        raise ValueError("invalid image tag")
    for component in ("web", "was"):
        path = DEPLOYMENTS[target] / component / "deployment.yaml"
        source = path.read_text()
        pattern = rf"(?m)^([ \t]*image:[ \t]*)\S*/petclinic-{component}:\S+[ \t]*$"
        result, count = re.subn(
            pattern,
            lambda match: f"{match.group(1)}{registry_user}/petclinic-{component}:{tag}",
            source,
        )
        if count != 1:
            raise ValueError(f"expected one {component} image in {path}, found {count}")
        path.write_text(result)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: update-image-tags.py aws|azure DOCKERHUB_USERNAME TAG")
    update(*sys.argv[1:])
