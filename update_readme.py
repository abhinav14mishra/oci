import re
import sys

status_file = sys.argv[1]
with open(status_file, "r") as f:
    status_content = f.read().strip()

block = f"<!-- OCI_STATUS_START -->\n{status_content}\n<!-- OCI_STATUS_END -->"

try:
    with open("README.md", "r") as f:
        content = f.read()

    if "<!-- OCI_STATUS_START -->" in content:
        new_content = re.sub(
            r"<!-- OCI_STATUS_START -->[\s\S]*?<!-- OCI_STATUS_END -->",
            block,
            content
        )
    else:
        new_content = content + f"\n\n## Deployment Status\n\n{block}\n"

    with open("README.md", "w") as f:
        f.write(new_content)
except FileNotFoundError:
    with open("README.md", "w") as f:
        f.write(f"# OpsPulse OCI Infrastructure\n\n## Deployment Status\n\n{block}\n")
