// Package aod is a Go client for the Agent on Demand API.
//
//	import "github.com/ravi-hq/agent-on-demand-ex/clients/go/aod"
//
//	c, _ := aod.New(aod.Config{BaseURL: "https://aod.example.com", Token: "..."})
//
//	agents, _ := c.Agents.List(ctx)
//	var agent aod.Agent
//	for _, a := range agents {
//	    if a.Name == "echo-bot" { agent = a; break }
//	}
//
//	conv, _ := c.Conversations.Create(ctx, aod.ConversationCreate{
//	    AgentID: agent.ID, Prompt: "Say hi",
//	})
//	result, _ := c.Conversations.WaitForResult(ctx, conv.ID)
//	fmt.Println(result)
package aod

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// ── core types ────────────────────────────────────────────────────

type Config struct {
	BaseURL string        // default: $AOD_BASE_URL or http://localhost:4000
	Token   string        // required
	HTTP    *http.Client  // default: &http.Client{Timeout: 30s}
}

type Client struct {
	baseURL string
	token   string
	http    *http.Client

	Agents        *AgentsResource
	Environments  *EnvironmentsResource
	Conversations *ConversationsResource
}

func New(cfg Config) (*Client, error) {
	base := cfg.BaseURL
	if base == "" {
		base = os.Getenv("AOD_BASE_URL")
	}
	if base == "" {
		base = "http://localhost:4000"
	}
	if cfg.Token == "" {
		return nil, errors.New("aod: Token is required")
	}
	httpc := cfg.HTTP
	if httpc == nil {
		httpc = &http.Client{Timeout: 30 * time.Second}
	}
	c := &Client{
		baseURL: strings.TrimRight(base, "/"),
		token:   cfg.Token,
		http:    httpc,
	}
	c.Agents = &AgentsResource{c: c}
	c.Environments = &EnvironmentsResource{c: c}
	c.Conversations = &ConversationsResource{c: c}
	return c, nil
}

// Error is returned for non-2xx responses.
type Error struct {
	Status int
	Body   []byte
}

func (e *Error) Error() string {
	return fmt.Sprintf("aod: API error %d: %s", e.Status, string(e.Body))
}

func (c *Client) request(ctx context.Context, method, path string, body, out any) error {
	var rdr io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(buf)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+"/api"+path, rdr)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode >= 400 {
		return &Error{Status: resp.StatusCode, Body: respBody}
	}
	if resp.StatusCode == http.StatusNoContent || len(respBody) == 0 || out == nil {
		return nil
	}

	// Server wraps successful responses as {"data": ...}.
	var envelope struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(respBody, &envelope); err == nil && len(envelope.Data) > 0 {
		return json.Unmarshal(envelope.Data, out)
	}
	return json.Unmarshal(respBody, out)
}

// ── schemas ───────────────────────────────────────────────────────
//
// Just the fields most callers reach for — the API may return more
// keys, json.Unmarshal ignores them. If you need everything raw, use
// the lower-level Client.Request() helper.

type Agent struct {
	ID            string                 `json:"id"`
	Name          string                 `json:"name"`
	Runtime       string                 `json:"runtime"`
	Model         string                 `json:"model"`
	System        string                 `json:"system"`
	Skills        []string               `json:"skills"`
	MCPServers    map[string]any         `json:"mcp_servers"`
	EnvironmentID string                 `json:"environment_id,omitempty"`
}

type Environment struct {
	ID               string         `json:"id"`
	Name             string         `json:"name"`
	Packages         map[string]any `json:"packages,omitempty"`
	EnvVars          map[string]any `json:"env_vars,omitempty"`
	NetworkingType   string         `json:"networking_type"`
	NetworkingConfig map[string]any `json:"networking_config,omitempty"`
	Repositories     []any          `json:"repositories,omitempty"`
	SetupScript      string         `json:"setup_script,omitempty"`
}

type Conversation struct {
	ID                string `json:"id"`
	Runtime           string `json:"runtime"`
	Status            string `json:"status"`
	AgentID           string `json:"agent_id,omitempty"`
	SandboxID         string `json:"sandbox_id,omitempty"`
	RuntimeSessionID  string `json:"runtime_session_id,omitempty"`
}

// ── resources ─────────────────────────────────────────────────────

type AgentsResource struct{ c *Client }

func (r *AgentsResource) List(ctx context.Context) ([]Agent, error) {
	var out []Agent
	return out, r.c.request(ctx, "GET", "/agents", nil, &out)
}
func (r *AgentsResource) Get(ctx context.Context, id string) (*Agent, error) {
	var out Agent
	return &out, r.c.request(ctx, "GET", "/agents/"+id, nil, &out)
}
func (r *AgentsResource) Create(ctx context.Context, fields map[string]any) (*Agent, error) {
	var out Agent
	return &out, r.c.request(ctx, "POST", "/agents", fields, &out)
}
func (r *AgentsResource) Update(ctx context.Context, id string, fields map[string]any) (*Agent, error) {
	var out Agent
	return &out, r.c.request(ctx, "PUT", "/agents/"+id, fields, &out)
}
func (r *AgentsResource) Delete(ctx context.Context, id string) error {
	return r.c.request(ctx, "DELETE", "/agents/"+id, nil, nil)
}

type EnvironmentsResource struct{ c *Client }

func (r *EnvironmentsResource) List(ctx context.Context) ([]Environment, error) {
	var out []Environment
	return out, r.c.request(ctx, "GET", "/environments", nil, &out)
}
func (r *EnvironmentsResource) Get(ctx context.Context, id string) (*Environment, error) {
	var out Environment
	return &out, r.c.request(ctx, "GET", "/environments/"+id, nil, &out)
}
func (r *EnvironmentsResource) Create(ctx context.Context, fields map[string]any) (*Environment, error) {
	var out Environment
	return &out, r.c.request(ctx, "POST", "/environments", fields, &out)
}
func (r *EnvironmentsResource) Update(ctx context.Context, id string, fields map[string]any) (*Environment, error) {
	var out Environment
	return &out, r.c.request(ctx, "PUT", "/environments/"+id, fields, &out)
}
func (r *EnvironmentsResource) Delete(ctx context.Context, id string) error {
	return r.c.request(ctx, "DELETE", "/environments/"+id, nil, nil)
}
func (r *EnvironmentsResource) AddSecret(ctx context.Context, envID, key, value string) (map[string]any, error) {
	var out map[string]any
	return out, r.c.request(ctx, "POST", "/environments/"+envID+"/secrets", map[string]string{"key": key, "value": value}, &out)
}
func (r *EnvironmentsResource) RemoveSecret(ctx context.Context, envID, key string) error {
	return r.c.request(ctx, "DELETE", "/environments/"+envID+"/secrets/"+key, nil, nil)
}

type ConversationCreate struct {
	AgentID string `json:"agent_id"`
	Prompt  string `json:"prompt"`
}

type ConversationsResource struct{ c *Client }

func (r *ConversationsResource) List(ctx context.Context) ([]Conversation, error) {
	var out []Conversation
	return out, r.c.request(ctx, "GET", "/conversations", nil, &out)
}
func (r *ConversationsResource) Get(ctx context.Context, id string) (*Conversation, error) {
	var out Conversation
	return &out, r.c.request(ctx, "GET", "/conversations/"+id, nil, &out)
}
func (r *ConversationsResource) Create(ctx context.Context, req ConversationCreate) (*Conversation, error) {
	var out Conversation
	return &out, r.c.request(ctx, "POST", "/conversations", req, &out)
}
func (r *ConversationsResource) Prompt(ctx context.Context, id, prompt string) (map[string]any, error) {
	var out map[string]any
	return out, r.c.request(ctx, "POST", "/conversations/"+id+"/prompts", map[string]string{"prompt": prompt}, &out)
}
func (r *ConversationsResource) Interrupt(ctx context.Context, id string) (*Conversation, error) {
	var out Conversation
	return &out, r.c.request(ctx, "POST", "/conversations/"+id+"/interrupt", nil, &out)
}
func (r *ConversationsResource) Terminate(ctx context.Context, id string) (*Conversation, error) {
	var out Conversation
	return &out, r.c.request(ctx, "POST", "/conversations/"+id+"/terminate", nil, &out)
}
func (r *ConversationsResource) Delete(ctx context.Context, id string) error {
	return r.c.request(ctx, "DELETE", "/conversations/"+id, nil, nil)
}

// ── streaming ─────────────────────────────────────────────────────

// Event is one parsed SSE event from /conversations/:id/stream.
type Event struct {
	ID     int
	Kind   string
	Stage  string
	Stream string
	State  string
	Data   any // inner runtime stream-json line (parsed when possible)
}

// StreamOpts controls a Stream() call.
type StreamOpts struct {
	Streams     []string // subset of {"stdout","stderr","stage"}; empty = all
	Wait        *bool    // nil/true: hold connection open; false: close after replay
	LastEventID int      // 0 = from start
}

// Stream returns a channel of parsed Events for the given conversation.
// Cancel the context to close the connection. The channel is closed
// when the server ends the stream, the context is cancelled, or an
// error occurs (delivered via the second return value's reader-error
// goroutine; caller should range until the channel closes).
//
// Most callers want WaitForResult instead.
func (r *ConversationsResource) Stream(ctx context.Context, convID string, opts StreamOpts) (<-chan Event, error) {
	q := url.Values{}
	if len(opts.Streams) > 0 {
		q.Set("streams", strings.Join(opts.Streams, ","))
	}
	if opts.Wait != nil && !*opts.Wait {
		q.Set("wait", "false")
	}

	endpoint := r.c.baseURL + "/api/conversations/" + convID + "/stream"
	if encoded := q.Encode(); encoded != "" {
		endpoint += "?" + encoded
	}
	req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+r.c.token)
	req.Header.Set("Accept", "text/event-stream")
	if opts.LastEventID > 0 {
		req.Header.Set("Last-Event-ID", strconv.Itoa(opts.LastEventID))
	}

	// Use a fresh client without a Timeout so the read can be long.
	httpc := &http.Client{Transport: r.c.http.Transport}
	resp, err := httpc.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return nil, &Error{Status: resp.StatusCode, Body: body}
	}

	ch := make(chan Event, 16)
	go func() {
		defer resp.Body.Close()
		defer close(ch)
		scanner := bufio.NewScanner(resp.Body)
		scanner.Buffer(make([]byte, 1<<16), 1<<22) // up to 4 MiB per line

		var (
			id   int
			kind = "message"
			data strings.Builder
		)
		flush := func() {
			if data.Len() == 0 {
				return
			}
			ev, ok := makeEvent(id, kind, data.String())
			data.Reset()
			id, kind = 0, "message"
			if !ok {
				return
			}
			select {
			case ch <- ev:
			case <-ctx.Done():
			}
		}

		for scanner.Scan() {
			line := scanner.Text()
			if line == "" {
				flush()
				continue
			}
			if strings.HasPrefix(line, ":") {
				continue // comment / heartbeat
			}
			switch {
			case strings.HasPrefix(line, "id: "):
				if n, err := strconv.Atoi(line[4:]); err == nil {
					id = n
				}
			case strings.HasPrefix(line, "event: "):
				kind = line[7:]
			case strings.HasPrefix(line, "data: "):
				data.WriteString(line[6:])
			}
		}
		flush()
	}()
	return ch, nil
}

// WaitForResult polls until the conversation leaves running/pending,
// then drains the SSE replay and returns the runtime's terminal text.
// Returns ("", nil) if no terminal text is found (e.g. failed turn).
func (r *ConversationsResource) WaitForResult(ctx context.Context, convID string) (string, error) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		conv, err := r.Get(ctx, convID)
		if err != nil {
			return "", err
		}
		if conv.Status != "running" && conv.Status != "pending" {
			wait := false
			ch, err := r.Stream(ctx, convID, StreamOpts{
				Streams: []string{"stdout"},
				Wait:    &wait,
			})
			if err != nil {
				return "", err
			}
			return finalText(ch, conv.Runtime), nil
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-ticker.C:
		}
	}
}

func makeEvent(id int, kind, raw string) (Event, bool) {
	var outer struct {
		Kind   string          `json:"kind"`
		Stream string          `json:"stream"`
		Stage  string          `json:"stage"`
		State  string          `json:"state"`
		Data   json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal([]byte(raw), &outer); err != nil {
		return Event{}, false
	}

	var inner any
	// `data` is usually a JSON-encoded string carrying the runtime's
	// stream-json line. Peel it; fall back to the raw value.
	var asString string
	if err := json.Unmarshal(outer.Data, &asString); err == nil {
		if jerr := json.Unmarshal([]byte(asString), &inner); jerr != nil {
			inner = asString
		}
	} else {
		_ = json.Unmarshal(outer.Data, &inner)
	}

	chosenKind := outer.Kind
	if chosenKind == "" {
		chosenKind = kind
	}
	return Event{
		ID:     id,
		Kind:   chosenKind,
		Stage:  outer.Stage,
		Stream: outer.Stream,
		State:  outer.State,
		Data:   inner,
	}, true
}

func finalText(ch <-chan Event, runtime string) string {
	var last string
	for ev := range ch {
		if ev.Kind != "output" {
			continue
		}
		m, ok := ev.Data.(map[string]any)
		if !ok {
			continue
		}
		typ, _ := m["type"].(string)
		switch runtime {
		case "claude":
			if typ == "result" {
				if s, _ := m["result"].(string); s != "" {
					return s
				}
			}
		case "codex":
			if typ == "item.completed" {
				if item, _ := m["item"].(map[string]any); item != nil {
					if itype, _ := item["type"].(string); itype == "agent_message" {
						if s, _ := item["text"].(string); s != "" {
							last = s
						}
					}
				}
			}
		case "gemini":
			if typ == "message" {
				if role, _ := m["role"].(string); role == "assistant" {
					if s, _ := m["content"].(string); s != "" {
						last = s
					}
				}
			}
		case "opencode":
			if typ == "text" {
				if part, _ := m["part"].(map[string]any); part != nil {
					if s, _ := part["text"].(string); s != "" {
						last += s
					}
				}
			}
		}
	}
	return last
}
