# Stage 1: Build & validation stage
FROM python:3.12.8-slim-bookworm AS builder

WORKDIR /build

# Validate python script syntax
COPY main.py .
RUN python3 -m py_compile main.py

# Stage 2: Minimal runtime stage
FROM python:3.12.8-slim-bookworm AS runtime

LABEL maintainer="Balu Nagireddy <balupower009@gmail.com>"
LABEL org.opencontainers.image.title="eb-demo-service"
LABEL org.opencontainers.image.description="Demo HTTP microservice for Enterprise Bot DevOps evaluation"

# Create a dedicated non-root user and group (UID/GID 10001)
RUN groupadd -g 10001 appgroup && \
    useradd -u 10001 -g appgroup -s /sbin/nologin -M appuser

WORKDIR /app

# Copy application source from builder
COPY --from=builder --chown=10001:10001 /build/main.py /app/main.py

# Switch to non-root user
USER 10001:10001

# Default environment configuration
ENV PORT=8080 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

EXPOSE 8080

ENTRYPOINT ["python3", "-u", "/app/main.py"]
