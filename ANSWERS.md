# Written Answers — Part 5

## Q1: Zero-Downtime Migration from `ingress-nginx` to Kubernetes Gateway API

### Approach & Sequence

1. **Prerequisites & Tooling**:
   - Install standard Gateway API CRDs (`GatewayClass`, `Gateway`, `HTTPRoute`, `ReferenceGrant`).
   - Deploy the new Gateway controller (e.g., Envoy Gateway or Cilium) alongside `ingress-nginx`.
   - Provision a shared `Gateway` listener bound to a dedicated external LoadBalancer IP.

2. **Route Translation & Coexistence**:
   - Translate ~40 Ingress manifests to `HTTPRoute` resources using `ingress2gateway` and validate manually.
   - Deploy `HTTPRoute`s in parallel with existing `Ingress` objects without modifying existing traffic flow. Both controllers target the same backend Services concurrently.

3. **Validation & Shadowing**:
   - Verify health and routing accuracy against the new Gateway VIP directly via synthetic header checks (`Host: api.example.com`).
   - Mirror/shadow a portion of production traffic if supported by the Gateway implementation.

4. **Phased Cutover (Canary DNS)**:
   - Shift production DNS traffic gradually via weighted records (e.g., Route53 / Cloudflare: 5% -> 25% -> 50% -> 100%).
   - Monitor 4xx/5xx error budgets, connection resets, and p95 latency.

5. **Decommission**:
   - Maintain `ingress-nginx` idle for 48 hours past full TTL expiration. Drain and remove `ingress-nginx` pods and retire the old LoadBalancer.

---

### What I Expect to Break Along the Way

- **Nginx Ingress Annotations**: Custom behaviors like regex path rewrites (`rewrite-target`), client body limits (`proxy-body-size`), snippets, and rate limits do not map 1:1. These require explicit `URLRewrite` filters or vendor-specific extension policies.
- **TLS & Certificate References**: Moving from per-Ingress `cert-manager.io/cluster-issuer` annotations to Gateway API requires re-anchoring cert issuance onto the `Gateway` listeners or managing `certificateRefs`.
- **Cross-Namespace Routing**: If routes target services across namespaces, missing `ReferenceGrant` objects will silently reject route attachments.
- **Client IP & Header Forwarding**: Inconsistent `X-Forwarded-For` / `X-Real-IP` handling and proxy protocol settings can break upstream geo-location, rate-limiting, and client authentication.

