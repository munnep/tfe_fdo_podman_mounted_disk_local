# Requirements:
#   pip install diagrams
#   brew install graphviz  # on macOS
#
# Run:
#   source venv/bin/activate
#   python3 diagram_tfe_fdo_podman_local.py
#
# Output:
#   diagram_tfe_fdo_podman_local.png

from diagrams import Cluster, Diagram, Edge
from diagrams.onprem.client import Client, Users
from diagrams.onprem.compute import Server
from diagrams.onprem.container import Docker
from diagrams.saas.cdn import Cloudflare

with Diagram(
    "TFE FDO Podman Local (macOS)",
    show=False,
    filename="diagram_tfe_fdo_podman_local",
    outformat="png",
    direction="LR",
):
    external_user = Users("External User")
    cloudflare_edge = Cloudflare("Cloudflare Edge\nDNS + TLS")

    with Cluster("macOS Host"):
        operator = Client("Operator")
        setup_script = Server("setup_tfe.sh\nrender + bootstrap")

        with Cluster("Podman"):
            podman_runtime = Docker("Podman runtime")

            with Cluster("terraform-enterprise Pod"):
                tfe_container = Server("Terraform Enterprise\nports 80 443 9090 9091 8446")
                cloudflared_container = Server("cloudflared\ntunnel client")

    operator >> Edge(label="runs") >> setup_script
    setup_script >> Edge(label="starts") >> podman_runtime

    external_user >> Edge(label="HTTPS to tfe5.munnep.com") >> cloudflare_edge
    cloudflare_edge >> Edge(label="tunnel") >> cloudflared_container
    cloudflared_container >> Edge(label="ingress to https://127.0.0.1:8443") >> tfe_container

    podman_runtime >> Edge(label="runs") >> tfe_container
    podman_runtime >> Edge(label="runs") >> cloudflared_container
