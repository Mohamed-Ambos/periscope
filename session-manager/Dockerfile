FROM docker:27-cli
RUN apk add --no-cache bash python3 py3-pip \
 && pip install --break-system-packages --no-cache-dir \
      fastapi==0.115.0 uvicorn==0.30.6 pyyaml==6.0.2
WORKDIR /app
COPY app.py /app/app.py
EXPOSE 8000
CMD ["python3", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
