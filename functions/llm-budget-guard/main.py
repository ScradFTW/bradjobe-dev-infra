"""Scales every node pool in the LLM cluster to 0 once its monthly budget is spent.

Triggered by the Pub/Sub topic that llm_budget_guard.tf's google_billing_budget
publishes to. Billing sends an update to that topic several times a day for the
rest of the month, so once the budget is exceeded this keeps re-zeroing the
pools. That includes undoing a `terraform apply` (which restores
llm_cpu_node_count) until the next calendar month resets costAmount.
"""

import base64
import json
import logging
import os

import functions_framework
from google.api_core import exceptions
from google.cloud import container_v1

PROJECT_ID = os.environ["PROJECT_ID"]
CLUSTER_LOCATION = os.environ["CLUSTER_LOCATION"]
CLUSTER_NAME = os.environ["CLUSTER_NAME"]


def over_budget(notification: dict) -> bool:
    return notification["costAmount"] >= notification["budgetAmount"]


@functions_framework.cloud_event
def handle_budget_notification(cloud_event):
    notification = json.loads(base64.b64decode(cloud_event.data["message"]["data"]))
    cost = notification["costAmount"]
    budget = notification["budgetAmount"]
    currency = notification.get("currencyCode", "")

    if not over_budget(notification):
        logging.info("LLM cluster spend %.2f/%.2f %s: under budget", cost, budget, currency)
        return

    logging.warning(
        "LLM cluster spend %.2f/%.2f %s: over budget, scaling node pools to 0",
        cost, budget, currency,
    )
    client = container_v1.ClusterManagerClient()
    cluster = f"projects/{PROJECT_ID}/locations/{CLUSTER_LOCATION}/clusters/{CLUSTER_NAME}"

    try:
        pools = client.list_node_pools(parent=cluster).node_pools
    except exceptions.NotFound:
        logging.info("%s does not exist; nothing to scale down", cluster)
        return

    for pool in pools:
        try:
            client.set_node_pool_size(name=f"{cluster}/nodePools/{pool.name}", node_count=0)
            logging.warning("Requested %s -> 0 nodes", pool.name)
        except (exceptions.FailedPrecondition, exceptions.Conflict) as e:
            # Another operation is already running on the cluster (often the
            # resize from a previous notification). The next notification
            # retries, so this doesn't need to fail the event.
            logging.warning("Could not resize %s yet: %s", pool.name, e)
