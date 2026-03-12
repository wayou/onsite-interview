# URL Shortener Service

Build a URL shortener service running on `localhost:8787`.

## API

### Create Short URL

```
POST /shorten
Content-Type: application/json

{"url": "https://example.com"}
```

Returns a JSON response containing a `short_url` field with the shortened URL.

### Redirect

```
GET /:code
```

Redirects to the original URL.

## Requirements

- Use any language or framework
- Service must listen on `http://localhost:8787`
- In-memory storage is fine (no database required)
