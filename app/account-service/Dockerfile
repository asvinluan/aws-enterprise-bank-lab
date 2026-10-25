FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
# Run as an unprivileged user, not root.
USER 10001
EXPOSE 8080
CMD ["python", "app.py"]
