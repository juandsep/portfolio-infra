"""Unlink billing from the project once the budget is exceeded.

Triggered by the budget's Pub/Sub notifications. Unlinking stops every paid
resource in the project; relink the billing account to bring it back.
"""

import base64
import json
import os

import functions_framework


def over_budget(notification: dict) -> bool:
    return notification["costAmount"] >= notification["budgetAmount"]


@functions_framework.cloud_event
def stop_billing(event) -> None:
    notification = json.loads(base64.b64decode(event.data["message"]["data"]))
    if not over_budget(notification):
        return

    from google.cloud import billing_v1

    client = billing_v1.CloudBillingClient()
    name = f"projects/{os.environ['PROJECT_ID']}"
    if client.get_project_billing_info(name=name).billing_enabled:
        client.update_project_billing_info(
            name=name, project_billing_info={"billing_account_name": ""}
        )
        print(f"billing disabled for {name}: {notification}")


if __name__ == "__main__":
    assert not over_budget({"costAmount": 19.99, "budgetAmount": 20})
    assert over_budget({"costAmount": 20, "budgetAmount": 20})
    assert over_budget({"costAmount": 35.5, "budgetAmount": 20})
    print("ok")
