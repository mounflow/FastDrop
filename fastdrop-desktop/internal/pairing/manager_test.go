package pairing

import (
	"errors"
	"testing"
	"time"
)

func newManager() *Manager { return NewManager(60 * time.Second) }

func TestIssueAndValidate(t *testing.T) {
	m := newManager()
	pt, err := m.Issue("MyPC", "192.168.1.5")
	if err != nil {
		t.Fatal(err)
	}
	if pt.PairID == "" || pt.Token == "" {
		t.Fatal("issue returned empty fields")
	}
	if pt.ExpiresAt.IsZero() {
		t.Fatal("expiry not set")
	}
	got, err := m.Validate(pt.PairID, pt.Token)
	if err != nil {
		t.Fatalf("validate: %v", err)
	}
	if !got.Consumed {
		t.Error("validated token not marked consumed")
	}
}

func TestTokenSingleUse(t *testing.T) {
	m := newManager()
	pt, _ := m.Issue("PC", "")
	if _, err := m.Validate(pt.PairID, pt.Token); err != nil {
		t.Fatal(err)
	}
	_, err := m.Validate(pt.PairID, pt.Token)
	if !errors.Is(err, ErrTokenAlreadyUsed) {
		t.Errorf("second use returned %v, want ErrTokenAlreadyUsed", err)
	}
}

func TestTokenWrongValueIncrementsFailures(t *testing.T) {
	m := newManager()
	pt, _ := m.Issue("PC", "")
	for i := 1; i <= 4; i++ {
		_, err := m.Validate(pt.PairID, "wrong-token")
		if !errors.Is(err, ErrTokenInvalid) {
			t.Fatalf("attempt %d: %v", i, err)
		}
	}
	// 5th failure should lock.
	_, err := m.Validate(pt.PairID, "wrong-token")
	if !errors.Is(err, ErrTokenLocked) {
		t.Errorf("5th failure: %v, want ErrTokenLocked", err)
	}
	// Locked: even the correct token should fail now.
	_, err = m.Validate(pt.PairID, pt.Token)
	if !errors.Is(err, ErrTokenLocked) {
		t.Errorf("correct token after lock: %v", err)
	}
}

func TestTokenExpired(t *testing.T) {
	m := newManager()
	m.now = func() time.Time { return time.Unix(1000, 0) }
	pt, _ := m.Issue("PC", "")
	// Advance clock past TTL.
	m.now = func() time.Time { return time.Unix(1000, 0).Add(2 * time.Minute) }
	_, err := m.Validate(pt.PairID, pt.Token)
	if !errors.Is(err, ErrTokenExpired) {
		t.Errorf("expired token: %v, want ErrTokenExpired", err)
	}
}

func TestUnknownPairID(t *testing.T) {
	m := newManager()
	_, err := m.Validate("nope", "x")
	if !errors.Is(err, ErrTokenInvalid) {
		t.Errorf("unknown pairID: %v", err)
	}
}

func TestRequestAcceptFlow(t *testing.T) {
	m := newManager()
	pt, _ := m.Issue("PC", "")
	if _, err := m.Validate(pt.PairID, pt.Token); err != nil {
		t.Fatal(err)
	}
	req, err := m.CreateRequest(pt.PairID, ClientDevice{DeviceID: "d1", DeviceName: "Phone", Platform: "android"})
	if err != nil {
		t.Fatal(err)
	}
	if req.Status != StatusWaitingConfirmation {
		t.Errorf("status = %q", req.Status)
	}
	// Before accept: status is waiting.
	got, ok := m.GetRequest(req.RequestID)
	if !ok || got.Status != StatusWaitingConfirmation {
		t.Errorf("get: %+v ok=%v", got, ok)
	}
	// Accept.
	if err := m.Accept(req.RequestID, AcceptResult{SessionID: "s1", SessionToken: "tok"}); err != nil {
		t.Fatal(err)
	}
	got, _ = m.GetRequest(req.RequestID)
	if got.Status != StatusAccepted || got.Result.SessionID != "s1" {
		t.Errorf("after accept: %+v", got)
	}
	// Cannot accept twice.
	if err := m.Accept(req.RequestID, AcceptResult{}); err == nil {
		t.Error("double accept should error")
	}
}

func TestRequestReject(t *testing.T) {
	m := newManager()
	pt, _ := m.Issue("PC", "")
	m.Validate(pt.PairID, pt.Token)
	req, _ := m.CreateRequest(pt.PairID, ClientDevice{DeviceID: "d1"})
	if err := m.Reject(req.RequestID, "user_rejected"); err != nil {
		t.Fatal(err)
	}
	got, _ := m.GetRequest(req.RequestID)
	if got.Status != StatusRejected || got.RejectReason != "user_rejected" {
		t.Errorf("after reject: %+v", got)
	}
}

func TestRequestExpiry(t *testing.T) {
	m := newManager()
	m.requestTTL = 1 * time.Second
	m.now = func() time.Time { return time.Unix(0, 0) }
	pt, _ := m.Issue("PC", "")
	m.Validate(pt.PairID, pt.Token)
	req, _ := m.CreateRequest(pt.PairID, ClientDevice{DeviceID: "d1"})
	m.now = func() time.Time { return time.Unix(0, 0).Add(2 * time.Second) }
	if err := m.Accept(req.RequestID, AcceptResult{}); err == nil {
		t.Error("accept after expiry should fail")
	}
	got, _ := m.GetRequest(req.RequestID)
	if got.Status != StatusExpired {
		t.Errorf("status = %q, want expired", got.Status)
	}
}

func TestRefreshIssuesNewTokenSamePairID(t *testing.T) {
	m := newManager()
	pt, _ := m.Issue("PC", "")
	old := pt.Token
	pt2, err := m.Refresh(pt.PairID, "PC", "")
	if err != nil {
		t.Fatal(err)
	}
	if pt2.PairID != pt.PairID {
		t.Error("refresh changed pairID")
	}
	if pt2.Token == old {
		t.Error("refresh did not rotate token")
	}
	// Old token should be invalid.
	_, err = m.Validate(pt.PairID, old)
	if err == nil {
		t.Error("old token still valid after refresh")
	}
	// New token works.
	if _, err := m.Validate(pt.PairID, pt2.Token); err != nil {
		t.Errorf("new token validate: %v", err)
	}
}

func TestCleanup(t *testing.T) {
	m := newManager()
	m.now = func() time.Time { return time.Unix(0, 0) }
	pt, _ := m.Issue("PC", "")
	m.Validate(pt.PairID, pt.Token)
	m.CreateRequest(pt.PairID, ClientDevice{DeviceID: "d"})
	// Advance clock well past expiry + grace.
	m.now = func() time.Time { return time.Unix(0, 0).Add(1 * time.Hour) }
	m.Cleanup()
	if _, ok := m.Lookup(pt.PairID); ok {
		t.Error("cleanup should have evicted the token")
	}
}
