# M3_006A: Website — Pending Items

**Prototype:** v1.0.0
**Milestone:** M3
**Workstream:** 006A
**Date:** Mar 5, 2026
**Status:** PENDING
**Priority:** P1 — Launch blocker
**Depends on:** M3_006 (Clerk auth foundation)

---

## 1.0 Summary

The usezombie.com website has several incomplete items blocking launch. These items cover branding, content, and functionality gaps across the landing page and navigation.

---

## 2.0 Pending Items

### 2.1 Logo Design

**Status:** PENDING

**Problem:** No official logo exists for usezombie.com.

**Requirements:**
- Create a distinctive logo representing the zombie/agent theme
- Must work at various sizes: favicon (16x16), nav bar (32x32), footer (larger)
- Should complement the slogan: "Undead. Unstoppable. 🧟 Sleep is for humans."
- Deliverables: SVG master + PNG exports in sizes: 16, 32, 64, 128, 256, 512px
- Optional: Animated version for hero section

**Dimensions:**
- 2.1.1 PENDING Source existing icon assets from `website/public/` or `assets/` for inspiration
- 2.1.2 PENDING Create SVG master logo
- 2.1.3 PENDING Generate PNG exports (16, 32, 64, 128, 256, 512px)
- 2.1.4 PENDING Optional: Create animated version for hero

---

### 2.2 Footer Logo

**Status:** PENDING

**Problem:** Footer lacks branding and slogan display.

**Requirements:**
- Add logo to footer component (`website/src/components/Footer.tsx`)
- Display slogan: "Undead. Unstoppable. 🧟 Sleep is for humans."
- Layout: Logo on left, slogan beneath or beside, social links on right
- Responsive: Stack vertically on mobile

**Dimensions:**
- 2.2.1 PENDING Import logo component into Footer.tsx
- 2.2.2 PENDING Implement responsive layout (desktop: horizontal, mobile: vertical stack)
- 2.2.3 PENDING Display slogan text with proper styling
- 2.2.4 PENDING Verify accessibility (alt text, contrast ratios)

---

### 2.3 Hero Section Visual

**Status:** PENDING

**Problem:** Hero section is text-only, lacks visual engagement.

**Requirements:**
- Add compelling imagery to hero section
- Must not distract from CTA buttons
- Optimize for performance (WebP format, lazy load below fold)

**Options (in order of preference):**
1. Custom illustration showing zombie/agent metaphor (character with terminal/commands)
2. Animated code visualization or terminal demo
3. Abstract tech pattern with zombie theme accents
4. Gradient/background image placeholder until custom art is ready

**Dimensions:**
- 2.3.1 PENDING Select visual approach from options above
- 2.3.2 PENDING Create/acquire visual asset
- 2.3.3 PENDING Implement in hero section with WebP format
- 2.3.4 PENDING Add lazy loading for below-fold content
- 2.3.5 PENDING Test responsive behavior on mobile/desktop

---

### 2.4 Book Team Pilot Functionality

**Status:** PENDING

**Problem:** "Book Team Pilot" button/link has no defined action.

**Requirements:**
- Define booking flow (choose one):
  1. **Calendly integration:** Embed calendar widget for scheduling 30-min demo calls
  2. **Typeform survey:** Collect team info (size, use case, timeline) then redirect to calendar
  3. **Email capture:** Simple form that sends to sales@usezombie.com
- Recommended: Option 1 (Calendly) for fastest implementation
- Track conversion with PostHog event: `team_pilot_booking_started`

**Dimensions:**
- 2.4.1 PENDING Select booking flow option
- 2.4.2 PENDING Configure booking service account (Calendly/Typeform)
- 2.4.3 PENDING Implement CTA button with tracking
- 2.4.4 PENDING Add PostHog event capture
- 2.4.5 PENDING Test end-to-end booking flow

**Implementation Reference:**
```tsx
<a 
  href="https://calendly.com/usezombie/team-pilot" 
  target="_blank" 
  rel="noopener noreferrer"
  onClick={() => posthog.capture('team_pilot_booking_started')}
>
  Book Team Pilot
</a>
```

---

### 2.5 Privacy Policy

**Status:** PENDING

**Problem:** Privacy page is missing or placeholder content.

**Requirements:**
- Create `/privacy` route and page component
- Must be reviewed by legal counsel before launch

**Policy Coverage:**
- Data collection: What we collect (email, usage data, workspace metadata)
- Data usage: How we use it (service provision, analytics, support)
- Data sharing: Third parties (Clerk for auth, PostHog for analytics, hosting providers)
- User rights: Access, deletion, portability (GDPR/CCPA compliance)
- Cookies: Essential vs. analytics cookies
- Contact: privacy@usezombie.com for inquiries
- Last updated date

**Dimensions:**
- 2.5.1 PENDING Create `/privacy` route in App.tsx
- 2.5.2 PENDING Create Privacy page component
- 2.5.3 PENDING Draft privacy policy content (base on Notion/similar template)
- 2.5.4 PENDING Add "Last updated" timestamp
- 2.5.5 PENDING Legal review (out of scope for implementation, mark as dependency)

---

### 2.6 Terms of Service

**Status:** PENDING

**Problem:** Terms page is missing or placeholder content.

**Requirements:**
- Create `/terms` route and page component
- Must be reviewed by legal counsel before launch

**Policy Coverage:**
- Service description: What usezombie provides
- User obligations: Acceptable use, account security
- Intellectual property: Ownership of code/data
- Limitation of liability: Service availability, data loss
- Termination: Account closure, data retention
- Governing law: Jurisdiction (Delaware/US recommended for SaaS)
- Changes to terms: Notification policy
- Contact: legal@usezombie.com

**Dimensions:**
- 2.6.1 PENDING Create `/terms` route in App.tsx
- 2.6.2 PENDING Create Terms page component
- 2.6.3 PENDING Draft terms content (base on Notion/similar template)
- 2.6.4 PENDING Add "Last updated" timestamp
- 2.6.5 PENDING Legal review (out of scope for implementation, mark as dependency)

---

### 2.7 Pricing Page 404

**Status:** PENDING

**Problem:** "View Full Pricing" link results in 404 error.

**Requirements:**
- Fix link destination to `/pricing`
- Verify route exists in `App.tsx` router
- Ensure Pricing page component renders correctly
- Add e2e test to prevent regression

**Dimensions:**
- 2.7.1 PENDING Verify route exists in App.tsx: `<Route path="/pricing" element={<Pricing />} />`
- 2.7.2 PENDING Fix "View Full Pricing" link destination
- 2.7.3 PENDING Verify Pricing component renders without errors
- 2.7.4 PENDING Add e2e test for pricing navigation

---

### 2.8 Discord Link Update

**Status:** PENDING

**Problem:** Discord link needs to point to specific invite.

**Requirements:**
- Update all Discord links to: `https://discord.gg/UtNUbtYK`
- Verify link is working (not expired, valid invite)

**Locations to Update:**
- Hero CTA section
- Footer social links
- Navigation (if present)
- Any other marketing sections

**Dimensions:**
- 2.8.1 PENDING Update Discord link in Hero section
- 2.8.2 PENDING Update Discord link in Footer
- 2.8.3 PENDING Update Discord link in Navigation (if applicable)
- 2.8.4 PENDING Verify invite link is active and not expired

---

## 3.0 Implementation Priority

| Priority | Section | Dependencies |
|----------|---------|--------------|
| P0 | 2.7 Pricing 404 | None |
| P0 | 2.8 Discord Link | None |
| P1 | 2.4 Book Team Pilot | Calendly account |
| P1 | 2.2 Footer Logo | 2.1 Logo Design |
| P1 | 2.1 Logo Design | None |
| P2 | 2.3 Hero Visual | 2.1 Logo Design |
| P2 | 2.5 Privacy Policy | Legal review |
| P2 | 2.6 Terms of Service | Legal review |

---

## 4.0 Acceptance Criteria

**Status:** PENDING

- [ ] 4.1 Logo appears in favicon and footer with correct slogan
- [ ] 4.2 Hero section displays visual element on desktop and mobile
- [ ] 4.3 "Book Team Pilot" opens booking flow (Calendly or equivalent)
- [ ] 4.4 `/privacy` page loads with complete policy text
- [ ] 4.5 `/terms` page loads with complete terms text
- [ ] 4.6 "View Full Pricing" navigates to `/pricing` without 404
- [ ] 4.7 All Discord links point to `https://discord.gg/UtNUbtYK`
- [ ] 4.8 All pages pass basic accessibility checks (WCAG 2.1 AA)

---

## 5.0 Technical Review

**Status:** PENDING

### 5.1 React 19 Features Not Utilized

**Current State:** Website uses React 19.1.0 but relies on legacy patterns (`useState`, `useEffect`).

**Recommendations for new features:**

| Feature | Benefit | Where to Use |
|---------|---------|--------------|
| `use()` hook | Cleaner data fetching, unwrap promises/context without useEffect | FAQ data loading, pricing tiers |
| `useOptimistic()` | Instant UI feedback on async actions | Form submissions (contact, waitlist) |
| `useFormStatus()` | Track form submission state natively | Contact forms, newsletter signup |
| `useActionState()` | Handle form errors/actions declaratively | Any form with server actions |
| Suspense boundaries | Better loading UX | Route transitions, data fetching |
| Refs as props | Simpler component APIs | Modal/dialog focus management |

**Migration Path:**
1. Keep existing code as-is (functional, tested)
2. Adopt new features incrementally in new components
3. Use `use()` for any new data fetching needs
4. Consider React Compiler (experimental) once stable for automatic memoization

**Priority:** Low — current patterns work fine; adopt new features opportunistically.

---

## 6.0 Out of Scope

- Full legal review of privacy/terms (consult counsel)
- Custom illustrations/animations (can use placeholders initially)
- Multi-language support
- Cookie consent banner (can be added post-launch if needed)
- Mission Control dashboard UI (covered in v3 specs)

---

## 7.0 Notes

- **Logo inspiration:** Check existing icon assets in repo for style guidance
- **Legal pages:** Consider using a generator like https://www.iubenda.com/ or https://termly.io/ for initial versions
- **Booking flow:** If Calendly is too complex initially, a simple mailto: link to founders@usezombie.com is acceptable for soft launch
