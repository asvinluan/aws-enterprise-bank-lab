"""
Meridian Bank account service - a stand-in for core banking.
Runs as a container on EKS. The balances are fictional.
"""

from flask import Flask, jsonify

app = Flask(__name__)

BALANCES = {
    "MB-770001": {"balance": "48120.55", "available": "45120.55"},
    "MB-770002": {"balance": "2301.10", "available": "2301.10"},
}


@app.route("/health")
def health():
    # Kubernetes calls this to decide whether the container is alive.
    return jsonify({"status": "ok"}), 200


@app.route("/accounts/<account_id>")
def get_account(account_id):
    record = BALANCES.get(account_id)
    if not record:
        return jsonify({"error": "not_found"}), 404
    return jsonify({"accountId": account_id, **record}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
