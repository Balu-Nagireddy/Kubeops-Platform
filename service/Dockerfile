# Stage 1: Build and validate
FROM python:3.12.15-alpine3.24 AS builder

WORKDIR /build

COPY main.py .

# Validate Python syntax
RUN python -m py_compile main.py


# Stage 2: Minimal runtime
FROM python:3.12.15-alpine3.24 AS runtime

# Create a dedicated non-root user (Alpine/BusyBox account utilities).
RUN addgroup -S -g 10001 appgroup && \
    adduser -S -D -H \
            -u 10001 \
            -G appgroup \
            -s /sbin/nologin \
            appuser

WORKDIR /app

# Copy validated application source
COPY --from=builder --chown=10001:10001 \
    /build/main.py ./main.py

# Runtime configuration
ENV PORT=8080 \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Document application port
EXPOSE 8080

# Run as non-root
USER 10001:10001

# Start application
ENTRYPOINT ["python", "-u", "/app/main.py"]
