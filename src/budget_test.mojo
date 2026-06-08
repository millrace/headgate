"""budget-test — unit-test the remote-API token Budget. `pixi run budget-test`."""

from budget import Budget, parse_budget


def _expect(name: String, cond: Bool, prev: Bool) -> Bool:
    print("[" + ("PASS" if cond else "FAIL") + "]", name)
    return prev and cond


def main() raises:
    var ok = True

    # unlimited (-1): never depleted
    var b1 = Budget(-1)
    ok = _expect("unlimited: not depleted", not b1.depleted(), ok)
    b1.charge(999999)
    ok = _expect("unlimited: not depleted after charge", not b1.depleted(), ok)
    ok = _expect("unlimited: remaining == -1", b1.remaining() == -1, ok)

    # zero (0): always depleted (always-local)
    var b2 = Budget(0)
    ok = _expect("zero: depleted from start", b2.depleted(), ok)

    # positive (100): depletes after spending the limit
    var b3 = Budget(100)
    ok = _expect("100: not depleted at start", not b3.depleted(), ok)
    ok = _expect("100: remaining == 100", b3.remaining() == 100, ok)
    b3.charge(60)
    ok = _expect("100: not depleted after 60", not b3.depleted(), ok)
    ok = _expect("100: remaining == 40", b3.remaining() == 40, ok)
    b3.charge(60)
    ok = _expect("100: depleted after 120", b3.depleted(), ok)
    ok = _expect("100: remaining clamped to 0", b3.remaining() == 0, ok)

    # parse_budget
    ok = _expect("parse '100' == 100", parse_budget(String("100")) == 100, ok)
    ok = _expect("parse '0' == 0", parse_budget(String("0")) == 0, ok)
    ok = _expect("parse '-1' == -1", parse_budget(String("-1")) == -1, ok)
    ok = _expect("parse '' == -1", parse_budget(String("")) == -1, ok)
    ok = _expect("parse 'abc' == -1", parse_budget(String("abc")) == -1, ok)

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("budget-test failed")
