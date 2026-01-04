# File: cli/Dockerfile
FROM python:3.13-slim

WORKDIR /app

# Install system dependencies for building packages (ADD THIS BLOCK)
RUN apt-get update && apt-get install -y \
    gcc \
    git \  
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy requirements and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY phone_directory.py .

# Create a non-root user
RUN useradd -m -u 1000 cliuser && chown -R cliuser:cliuser /app
USER cliuser

# Default command (can be overridden in docker-compose)
CMD ["python", "phone_directory.py"]