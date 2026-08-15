# SSC Masterlist Integration Guide for External Projects

> **Target Audience:** Developers building external applications, Registrar Systems, or Department Portals that need to query student enrollment masterlist data from the CJC Student Services Center (SSC) System.

---

## 1. Overview & Capabilities

The **SSC Masterlist Integration API** provides a secure, read-only, machine-to-machine HTTP surface under `/api/v1/integration/**`. 

### Key Features
* **Machine-to-Machine Authentication**: No user sessions or OAuth tokens required. Simple HTTP header (`X-API-Key`).
* **Filtering**: Filter students by department (`departmentId`), status (`active`), or keyword search (`search`).
* **Pagination & Sorting**: Built-in Spring Data pagination (`page`, `size`, `sort`) for efficient data fetching.
* **Granular Data Sensitivity**: Sensitive fields (birthdate, emergency contacts) are hidden by default unless explicitly requested and permitted for your API key.
* **Strictly Read-Only**: Prevents unauthorized modifications (all `POST`/`PUT`/`DELETE` calls return `405 Method Not Allowed`).

---

## 2. Authentication & Authorization

All requests to the integration surface must include the **`X-API-Key`** header:

```http
GET /api/v1/integration/masterlist HTTP/1.1
Host: your-ssc-domain.com
X-API-Key: YOUR_CONFIGURED_API_KEY
```

> 🔑 **Obtaining an API Key:** Request an API key from the SSC System Administrator. Each key is bound to a client identifier (e.g., `registrar-system`) and assigned explicit permissions.

---

## 3. API Endpoints

### A. Search & Filter Masterlist (Paginated)

Retrieves a paginated list of students matching the provided search and filter criteria.

* **Endpoint**: `GET /api/v1/integration/masterlist`
* **Query Parameters**:

| Parameter | Type | Default | Description | Example |
|---|---|---|---|---|
| `departmentId` | `String` | `null` | Filter by academic department ID | `dept-cs` |
| `search` | `String` | `null` | Keyword search in name, student ID, or email | `Juan` or `2026-001` |
| `active` | `Boolean` | `null` | Filter by active enrollment status (`true`/`false`) | `true` |
| `includeSensitive` | `Boolean` | `false` | Include sensitive fields (birthdate, emergency contact) | `false` |
| `page` | `Integer` | `0` | Zero-indexed page number | `0` |
| `size` | `Integer` | `20` | Number of items per page (max `100`) | `20` |
| `sort` | `String` | `studentId,asc` | Sort field and direction (`field,asc\|desc`) | `familyName,asc` |

#### Request Example (cURL)
```bash
curl -X GET \
  -H "X-API-Key: YOUR_API_KEY" \
  "http://localhost:9004/api/v1/integration/masterlist?departmentId=dept-cs&search=Juan&page=0&size=10"
```

#### Response Example (`200 OK`)
```json
{
  "content": [
    {
      "studentId": "2026-00101",
      "email": "student@g.cjc.edu.ph",
      "firstName": "Juan",
      "lastName": "Dela Cruz",
      "middleName": "Santos",
      "departmentId": "dept-cs",
      "departmentName": "College of Computer Studies",
      "courseId": "bsit",
      "courseName": "BS in Information Technology",
      "yearLevel": 3,
      "academicStatus": "REGULAR",
      "status": "ENROLLED"
    }
  ],
  "pageable": {
    "pageNumber": 0,
    "pageSize": 10
  },
  "totalPages": 1,
  "totalElements": 1,
  "last": true,
  "first": true,
  "size": 10,
  "number": 0,
  "numberOfElements": 1,
  "empty": false
}
```

---

### B. Single Student Lookup

Retrieves a single student's record by their Student ID.

* **Endpoint**: `GET /api/v1/integration/masterlist/{studentId}`
* **Path Parameter**: `studentId` (e.g. `2026-00101`)
* **Query Parameters**:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `includeSensitive` | `Boolean` | `false` | Set to `true` to include sensitive contact & birth details |

#### Request Example (cURL)
```bash
curl -X GET \
  -H "X-API-Key: YOUR_API_KEY" \
  "http://localhost:9004/api/v1/integration/masterlist/2026-00101?includeSensitive=true"
```

#### Response Example (`200 OK`)
```json
{
  "studentId": "2026-00101",
  "email": "student@g.cjc.edu.ph",
  "firstName": "Juan",
  "lastName": "Dela Cruz",
  "middleName": "Santos",
  "departmentId": "dept-cs",
  "departmentName": "College of Computer Studies",
  "courseId": "bsit",
  "courseName": "BS in Information Technology",
  "yearLevel": 3,
  "academicStatus": "REGULAR",
  "status": "ENROLLED",
  "dateOfBirth": "2004-05-15",
  "contactNumber": "+639171234567",
  "emergencyContactName": "Maria Dela Cruz",
  "emergencyContactNumber": "+639189876543"
}
```

---

### C. Reference Directories (Departments & Organizations)

External callers can also resolve department and organization IDs:

* **Get All Active Departments**: `GET /api/v1/integration/departments`
* **Get Department by ID**: `GET /api/v1/integration/departments/{id}`
* **Get All Organizations**: `GET /api/v1/integration/organizations`

---

## 4. Code Integration Examples

### JavaScript / Node.js (`fetch`)
```javascript
const API_KEY = "YOUR_API_KEY";
const BASE_URL = "http://localhost:9004/api/v1/integration";

async function fetchDepartmentMasterlist(departmentId, page = 0) {
  const url = `${BASE_URL}/masterlist?departmentId=${encodeURIComponent(departmentId)}&page=${page}&size=20`;
  
  const response = await fetch(url, {
    method: "GET",
    headers: {
      "X-API-Key": API_KEY,
      "Accept": "application/json"
    }
  });

  if (!response.ok) {
    throw new Error(`API Error: ${response.status} ${response.statusText}`);
  }

  const data = await response.json();
  console.log(`Retrieved ${data.content.length} students of ${data.totalElements} total.`);
  return data;
}
```

### Python (`requests`)
```python
import requests

API_KEY = "YOUR_API_KEY"
BASE_URL = "http://localhost:9004/api/v1/integration"

headers = {
    "X-API-Key": API_KEY,
    "Accept": "application/json"
}

def search_students(query, department_id=None, page=0, size=20):
    params = {
        "search": query,
        "departmentId": department_id,
        "page": page,
        "size": size
    }
    response = requests.get(f"{BASE_URL}/masterlist", headers=headers, params=params)
    response.raise_for_status()
    return response.json()

# Example: Search for "Juan" in CS department
results = search_students(query="Juan", department_id="dept-cs")
print(f"Total matching: {results['totalElements']}")
```

---

## 5. HTTP Error Codes & Troubleshooting

| HTTP Code | Error Message | Solution |
|---|---|---|
| `401 Unauthorized` | Missing `X-API-Key` header | Provide the `X-API-Key` header in your request. |
| `403 Forbidden` | Invalid API key or client not permitted | Check your API key. If requesting `includeSensitive=true`, verify that your client has sensitive data access enabled. |
| `404 Not Found` | Masterlist record not found | Verify the `studentId` path variable. |
| `405 Method Not Allowed` | The integration API is read-only | Only `GET` requests are allowed on `/api/v1/integration/**`. |
| `429 Too Many Requests` | Rate limit exceeded | Slow down your request rate. Requests are bucket-limited per API key. |
