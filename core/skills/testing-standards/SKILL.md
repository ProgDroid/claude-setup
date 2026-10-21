---
name: testing-standards
description: Use when writing, reviewing or debugging tests in any language - test design, mutation checks, timing bounds, flake handling.
---

# Testing Standards (Cross-Language)

## Testing Philosophy

### Test Pyramid
```
        /\
       /  \        E2E Tests (Few)
      /----\       - Critical user journeys
     /      \      - Smoke tests
    /--------\     Integration Tests (Some)
   /          \    - API contracts
  /------------\   - Database interactions
 /              \  Unit Tests (Many)
/________________\ - Business logic
                   - Pure functions
```

### Guiding Principles
1. **Test behavior, not implementation** - Tests should verify what code does, not how
2. **Arrange-Act-Assert (AAA)** - Clear structure in every test
3. **One assertion per concept** - Tests should fail for one reason
4. **Deterministic** - No flaky tests; mock external dependencies
5. **Fast** - Unit tests should run in milliseconds
6. **Independent** - Tests should not depend on each other

## Coverage Requirements

| Type | Minimum | Target |
|------|---------|--------|
| Unit | 80% | 90% |
| Branch | 75% | 85% |
| Integration | Critical paths | All APIs |
| E2E | Happy paths | Key journeys |

### What to Cover
- Business logic and domain rules
- Edge cases and boundary conditions
- Error handling paths
- Input validation

### What NOT to Cover
- Third-party library internals
- Simple getters/setters
- Framework boilerplate
- Generated code

## Test Naming Convention

### Format
```
test_<unit>_<scenario>_<expected_result>
```

### Examples
```python
# Python
def test_calculate_total_with_discount_returns_reduced_price():
def test_user_login_with_invalid_password_raises_auth_error():
def test_order_submit_when_cart_empty_returns_validation_error():
```

```typescript
// TypeScript
describe('calculateTotal', () => {
  it('returns reduced price when discount applied', () => {});
  it('throws error when items array is empty', () => {});
});
```

```go
// Go
func TestCalculateTotal_WithDiscount_ReturnsReducedPrice(t *testing.T) {}
func TestUserLogin_InvalidPassword_ReturnsAuthError(t *testing.T) {}
```

## Test Structure (AAA Pattern)

### Arrange-Act-Assert
```python
def test_user_creation_with_valid_data_succeeds():
    # Arrange - Set up test data and dependencies
    user_data = {"name": "Alice", "email": "alice@example.com"}
    repository = MockUserRepository()

    # Act - Execute the code under test
    service = UserService(repository)
    result = service.create_user(user_data)

    # Assert - Verify the outcome
    assert result.name == "Alice"
    assert result.email == "alice@example.com"
    repository.save.assert_called_once()
```

### Given-When-Then (BDD Style)
```typescript
describe('ShoppingCart', () => {
  describe('when adding an item', () => {
    it('should increase total by item price', () => {
      // Given
      const cart = new ShoppingCart();
      const item = { id: '1', price: 10.00 };

      // When
      cart.addItem(item);

      // Then
      expect(cart.total).toBe(10.00);
    });
  });
});
```

## Unit Testing

### Characteristics
- Tests single unit (function, method, class)
- No external dependencies (DB, network, filesystem)
- Runs in isolation
- Fast (< 100ms per test)

### Mocking Guidelines
```python
# Mock at boundaries, not everywhere
# Good: Mock external service
@patch('myapp.services.external_api.fetch_data')
def test_process_data_transforms_correctly(mock_fetch):
    mock_fetch.return_value = {"value": 42}
    result = process_data()
    assert result == {"transformed": 42}

# Bad: Mocking internal implementation details
@patch('myapp.services.processor._internal_helper')  # Don't do this
```

### Test Doubles
| Type | Purpose | Example |
|------|---------|---------|
| **Stub** | Provide canned answers | `mock.return_value = 42` |
| **Mock** | Verify interactions | `mock.assert_called_with(x)` |
| **Fake** | Working implementation | In-memory database |
| **Spy** | Record calls, use real impl | `jest.spyOn(obj, 'method')` |

## Integration Testing

### Characteristics
- Tests component interactions
- May use real databases (containerized)
- Tests API contracts
- Slower than unit tests (seconds)

### Database Testing Pattern
```python
# Use transactions for isolation
@pytest.fixture
def db_session():
    connection = engine.connect()
    transaction = connection.begin()
    session = Session(bind=connection)

    yield session

    session.close()
    transaction.rollback()
    connection.close()

def test_user_repository_saves_user(db_session):
    repo = UserRepository(db_session)
    user = User(name="Alice")

    repo.save(user)

    saved = repo.find_by_name("Alice")
    assert saved is not None
    assert saved.name == "Alice"
```

### API Testing Pattern
```typescript
// Testing Express/Fastify endpoints
describe('POST /api/users', () => {
  it('creates user and returns 201', async () => {
    const response = await request(app)
      .post('/api/users')
      .send({ name: 'Alice', email: 'alice@example.com' })
      .expect(201);

    expect(response.body).toMatchObject({
      id: expect.any(String),
      name: 'Alice',
      email: 'alice@example.com',
    });
  });

  it('returns 400 for invalid email', async () => {
    const response = await request(app)
      .post('/api/users')
      .send({ name: 'Alice', email: 'invalid' })
      .expect(400);

    expect(response.body.error).toContain('email');
  });
});
```

## E2E Testing

### Characteristics
- Tests complete user journeys
- Uses real browser/client
- Tests against deployed environment
- Slowest (seconds to minutes)

### Playwright Pattern
```typescript
// e2e/checkout.spec.ts
import { test, expect } from '@playwright/test';

test.describe('Checkout Flow', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Login' }).click();
    await page.fill('[name="email"]', 'test@example.com');
    await page.fill('[name="password"]', 'password');
    await page.click('button[type="submit"]');
  });

  test('completes purchase successfully', async ({ page }) => {
    // Add item to cart
    await page.goto('/products/1');
    await page.getByRole('button', { name: 'Add to Cart' }).click();

    // Go to checkout
    await page.goto('/cart');
    await page.getByRole('button', { name: 'Checkout' }).click();

    // Fill payment
    await page.fill('[name="cardNumber"]', '4242424242424242');
    await page.fill('[name="expiry"]', '12/25');
    await page.fill('[name="cvc"]', '123');

    // Complete order
    await page.getByRole('button', { name: 'Pay Now' }).click();

    // Verify success
    await expect(page.getByText('Order Confirmed')).toBeVisible();
    await expect(page).toHaveURL(/\/orders\/\w+/);
  });
});
```

## Test Data Management

### Fixtures Pattern
```python
# conftest.py
import pytest
from datetime import datetime

@pytest.fixture
def sample_user():
    return {
        "id": "user-123",
        "name": "Test User",
        "email": "test@example.com",
        "created_at": datetime(2024, 1, 1),
    }

@pytest.fixture
def sample_order(sample_user):
    return {
        "id": "order-456",
        "user_id": sample_user["id"],
        "items": [
            {"product_id": "prod-1", "quantity": 2, "price": 10.00},
        ],
        "total": 20.00,
    }
```

### Factory Pattern
```typescript
// test/factories/user.ts
import { faker } from '@faker-js/faker';

export function createUser(overrides: Partial<User> = {}): User {
  return {
    id: faker.string.uuid(),
    name: faker.person.fullName(),
    email: faker.internet.email(),
    createdAt: faker.date.past(),
    ...overrides,
  };
}

// Usage
const user = createUser({ name: 'Alice' });
const admin = createUser({ role: 'admin' });
```

## Handling Async Tests

### Python (pytest-asyncio)
```python
import pytest

@pytest.mark.asyncio
async def test_async_operation():
    result = await async_function()
    assert result == expected
```

### TypeScript/JavaScript
```typescript
// With async/await
it('fetches user data', async () => {
  const user = await fetchUser('123');
  expect(user.name).toBe('Alice');
});

// With done callback (avoid if possible)
it('handles callback', (done) => {
  fetchWithCallback((err, data) => {
    expect(data).toBeDefined();
    done();
  });
});
```

### Go
```go
func TestAsyncOperation(t *testing.T) {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    resultCh := make(chan Result)
    go func() {
        result, _ := asyncOperation(ctx)
        resultCh <- result
    }()

    select {
    case result := <-resultCh:
        assert.Equal(t, expected, result)
    case <-ctx.Done():
        t.Fatal("test timed out")
    }
}
```

## Snapshot Testing

### When to Use
- Complex UI components
- API response structures
- Configuration outputs
- Serialized data

### When NOT to Use
- Frequently changing data
- Random/timestamp values
- Large objects (hard to review)

```typescript
// Jest/Vitest snapshot
it('renders correctly', () => {
  const { container } = render(<UserCard user={mockUser} />);
  expect(container).toMatchSnapshot();
});

// Inline snapshot (preferred for small data)
it('transforms data correctly', () => {
  const result = transform(input);
  expect(result).toMatchInlineSnapshot(`
    {
      "name": "Alice",
      "status": "active",
    }
  `);
});
```

## CI Integration

### Test Commands
```yaml
# GitHub Actions example
test:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v5

    - name: Unit Tests
      run: |
        pnpm test:unit --coverage

    - name: Integration Tests
      run: |
        docker-compose up -d
        pnpm test:integration
        docker-compose down

    - name: E2E Tests
      run: |
        pnpm build
        pnpm test:e2e

    - name: Upload Coverage
      uses: codecov/codecov-action@v5
```

### Parallel Execution
```bash
# pytest
pytest -n auto  # Uses pytest-xdist

# vitest
vitest --pool=threads

# go
go test -parallel 4 ./...
```

## Flaky Test Prevention

### Common Causes & Solutions
| Cause | Solution |
|-------|----------|
| Race conditions | Use proper synchronization |
| Time-dependent | Mock time/use fixed timestamps |
| Order-dependent | Ensure test isolation |
| External services | Mock or use containers |
| Resource cleanup | Use proper teardown |

### Wall-clock bounds: set them from two measurements

A test that asserts "X takes under N" guards a performance bug, so N must sit between the GOOD time
and the BAD time with margin both ways. Measure both: the good time **under realistic load** (the
whole suite running in parallel, not the test alone), and the bad time **from a mutant** (restore
the slow code, on a quiet machine, which is its fastest). Put N near their geometric mean, and write
both numbers in a comment beside the bound. When N is a real requirement (a hook's own timeout),
keep it and say so. A bound guessed from one quiet run is the usual source of "flaky" timing tests.

### Retry Strategy (Last Resort)
```typescript
// vitest.config.ts
export default {
  test: {
    retry: process.env.CI ? 2 : 0,
  },
};
```

## Diagnosing Hung DB Tests in CI (when you can't reproduce locally)

If a CI test job hangs with no output and you have no local DB (e.g. Docker
unavailable), instrument rather than guess:

1. **Add `pytest-timeout`** with `timeout_method = "thread"` (dumps the wedged
   test's stack and hard-exits the process). Turns an opaque multi-hour hang
   into a ~2-min traceback that localizes it — usually to a fixture.
2. **For a DB lock hang** (traceback ends in a blocked `DROP`/`DELETE` inside a
   fixture), set a per-connection `lock_timeout`/`statement_timeout` on the
   *test* engine so the blocked statement fails with the **named** test instead
   of hanging: `create_engine(url, connect_args={"options": "-c lock_timeout=30000 -c statement_timeout=120000"})`.

**Root-cause gotcha (SQLAlchemy):** a `Session` used *after* its `with` block
has closed it silently auto-begins a new, never-closed transaction — its
`ACCESS SHARE` locks then block the fixture teardown's `DROP TABLE`, hanging
CI. Keep every session use inside its `with`; capture the result dict/value and
assert on it afterwards. (Cost real hours on ds-job-analysis, 2026-07-24.)

**Harden the fixture:** a per-test `drop_all`/`create_all` engine should use
`poolclass=NullPool` + `engine.dispose()` in a `finally`, so no connection
lingers between tests to hold a lock. These guards (plus `pytest-timeout`) are
worth keeping permanently — they convert a silent hang into a fast named error.
