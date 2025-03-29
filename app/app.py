from flask import Flask
app = Flask(__name__)

@app.route('/')
def hello():
    return "Hello, World! 1234567", 200  # Explicit status code

@app.route('/health')
def health():
    """Explicit health check endpoint for Kubernetes"""
    return "OK", 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)  # debug=False for production