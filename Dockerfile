FROM python:3.14-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 APP_ENV=production
WORKDIR /app
COPY requirements.lock ./
RUN pip install --no-cache-dir -r requirements.lock && useradd --uid 10001 --create-home app
COPY --chown=app:app app.py wsgi.py gunicorn.conf.py ./
COPY --chown=app:app nightlibrary ./nightlibrary
COPY --chown=app:app templates ./templates
COPY --chown=app:app static ./static
COPY --chown=app:app sql ./sql
USER 10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/ready',timeout=4)" || exit 1
CMD ["gunicorn","--config","gunicorn.conf.py","wsgi:application"]
