from flask import Flask, jsonify
import flask as flask_pkg

app = Flask(__name__)

@app.get("/")
def index():
    return jsonify({
        "status": "ok",
        "flask_version": flask_pkg.__version__
    })

if __name__ == "__main__":
    # For demo only; use gunicorn in real apps
    app.run(host="0.0.0.0", port=5000, debug=False)
