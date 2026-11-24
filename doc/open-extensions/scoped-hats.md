# Scoped Hats (ProtoXEP)

| | |
|---|---|
| **Title** | Scoped Hats |
| **Short name** | scoped-hats |
| **Status** | ProtoXEP (not yet submitted to the XSF) |
| **Type** | Standards Track |
| **Extends** | [XEP-0317: Hats](https://xmpp.org/extensions/xep-0317.html) |
| **Depends on** | XEP-0030, XEP-0045, XEP-0317 |
| **Namespace** | `urn:xmpp:scoped-hats:0` (provisional, until assigned by the XMPP Registrar) |
| **Version** | 0.1.0 (2026-11-23), first draft |
| **Implementation** | MongooseIM `mod_muc`, option [`scoped_hats`](../modules/mod_muc.md#modulesmod_mucscoped_hats) |

## 1. Abstract

This specification extends XEP-0317 (Hats) so that a hat can be worn for a limited audience.
A scoped hat is shown only to the room occupants named in its audience,
and in particular a *pairwise* hat is a hat between two occupants that only those two see on each other.
Occupants outside the audience receive nothing that reveals the hat, and clients that do not
implement this specification never see it.

## 2. Introduction

XEP-0317 lets a room give an occupant a hat, such as "Host" or "Moderator on duty",
which the room adds to every presence it sends for that occupant.
Hats are room-wide by design: every occupant sees every hat.

Some relationships between occupants are not room-wide.
Two occupants may have matched with each other, be on the same team inside a larger event room,
or have a host-to-guest relationship that the other guests should not see.
Today a service has to fall back on private messages or out-of-band data to show these,
which loses the place where clients already render roles: next to the occupant in the room roster.

Scoped hats keep the XEP-0317 hat model (a URI, a title and an optional hue, defined once per room)
and add one thing: an assignment may name an audience.
The room then includes the hat only in the presences of the wearer that it sends to the audience.

## 3. Requirements

1. A hat can be worn for an audience of one or more occupants, identified by bare JID.
2. A pairwise hat, worn by each of two occupants for the other, can be created in one operation.
3. Only the audience receives the hat; no other occupant can learn that it exists, who wears it,
   who sees it, or when it changes.
4. A client that does not implement this specification never displays a scoped hat.
5. Clients cannot put scoped hats on themselves.
6. Scoped hats reuse the hats defined in the room by XEP-0317.
7. The extension is optional for both rooms and clients, and discoverable.

## 4. Glossary

* **Wearer**: the occupant who wears a hat.
* **Viewer**: an occupant who receives the hat in the wearer's presence.
* **Audience**: the set of viewers of a scoped hat assignment, as bare JIDs.
* **Scoped hat assignment**: the triple (wearer, hat URI, viewer). An assignment with an audience
  of several viewers is the same as one assignment per viewer.
* **Pairwise hat**: the two assignments (A, hat, B) and (B, hat, A).
* **Room-wide hat**: a hat assigned as in XEP-0317, seen by every occupant.

## 5. Use Cases

### 5.1 A viewer receives a scoped hat

Juliet wears the hat `http://example.com/hats#match` for Romeo only.
When the room sends Juliet's presence to Romeo, it adds a `<scoped-hats/>` element:

```xml
<presence from='party@chat.example.com/Juliet'
          to='romeo@example.net/orchard'
          id='a3b1'>
  <x xmlns='http://jabber.org/protocol/muc#user'>
    <item affiliation='member' role='participant'/>
  </x>
  <scoped-hats xmlns='urn:xmpp:scoped-hats:0'>
    <hat uri='http://example.com/hats#match' title='Your match' hue='300'/>
  </scoped-hats>
</presence>
```

The same presence sent to any other occupant, for example Mercutio, carries no `<scoped-hats/>` element:

```xml
<presence from='party@chat.example.com/Juliet'
          to='mercutio@example.org/street'
          id='a3b2'>
  <x xmlns='http://jabber.org/protocol/muc#user'>
    <item affiliation='member' role='participant'/>
  </x>
</presence>
```

The element carries no audience information. A viewer only learns that the wearer shows the hat to them,
and never learns who else may see it.

### 5.2 A pairwise hat

When the hat is pairwise, Romeo also wears it for Juliet, so Juliet receives it in Romeo's presence.
Each of them sees the hat on the other, and nobody else sees it on either of them.

### 5.3 Room-wide and scoped hats together

A wearer can have both. Room-wide hats stay in the XEP-0317 `<hats/>` element,
and scoped hats go in the `<scoped-hats/>` element:

```xml
<presence from='party@chat.example.com/Juliet' to='romeo@example.net/orchard'>
  <x xmlns='http://jabber.org/protocol/muc#user'>
    <item affiliation='member' role='participant'/>
  </x>
  <hats xmlns='urn:xmpp:hats:0'>
    <hat uri='http://example.com/hats#host' title='Host'/>
  </hats>
  <scoped-hats xmlns='urn:xmpp:scoped-hats:0'>
    <hat uri='http://example.com/hats#match' title='Your match'/>
  </scoped-hats>
</presence>
```

### 5.4 Assigning and removing scoped hats

Rooms manage scoped hats as an administrative operation, like XEP-0317 hats.
This specification defines optional ad-hoc commands (Section 7) for that,
and a service may offer other interfaces, such as an administration API (see Section 13).

An assignment names the wearer, a hat defined in the room, the audience, and whether it is mutual.
A mutual assignment also makes every audience member wear the hat for the wearer,
so a mutual assignment with an audience of one creates a pairwise hat.

A removal names the wearer, the hat, and either an audience or no audience (meaning every viewer).
A mutual removal also takes the hat off the audience members who wear it for the wearer.

When an assignment is added or removed, the room sends the wearer's current presence again,
**only to the affected viewers**.

## 6. Protocol

### 6.1 The `<scoped-hats/>` element

The `<scoped-hats/>` element, qualified by the `urn:xmpp:scoped-hats:0` namespace,
appears as a direct child of a presence that a room sends on behalf of an occupant.
It contains one or more `<hat/>` elements. Each `<hat/>` element has the same attributes
and meaning as the `<hat/>` element of XEP-0317:

| Attribute | Required | Meaning |
|---|---|---|
| `uri` | yes | The URI that identifies the hat, unique within the room |
| `title` | yes | A human-readable title |
| `hue` | no | A hue in degrees, at least 0 and less than 360, as in XEP-0317 |

The `<hat/>` children are qualified by the `urn:xmpp:scoped-hats:0` namespace, inherited from the parent.

### 6.2 Presence fan-out rule

For every presence the room sends on behalf of a wearer W to an occupant session whose bare JID is V,
the room MUST compute the scoped hats as the hats of all assignments (W, hat, V), and then:

1. If W and V are the same bare JID, the set is empty: an occupant is never a viewer of its own hats.
2. Hats that W also wears room-wide MUST be left out, because the viewer already receives them in `<hats/>`.
3. If the set is empty, the room MUST NOT include a `<scoped-hats/>` element.
4. Otherwise the room MUST include exactly one `<scoped-hats/>` element listing them.

This applies to every presence the room sends for an occupant:
the presences sent to a joining occupant for the existing occupants,
the broadcast of a new or changed presence, nick changes (XEP-0045 status 303),
and the presence sent again after a hats change.
Unavailable presences carry no hats.

All of the viewer's sessions in the room receive the scoped hats, since the audience is a bare JID.

### 6.3 Re-sending after a change

When scoped hat assignments change, or a hat that is worn scoped is redefined or removed,
the room MUST send the wearer's current presence to the affected viewers' sessions,
and MUST NOT send it to any other occupant, including the wearer.
This keeps the change invisible to everyone outside the audience, timing included.

### 6.4 Client-provided elements

A room that implements this specification MUST remove any `<scoped-hats/>` element (and any XEP-0317
`<hats/>` element) from the presences that clients send to it, before storing or broadcasting them,
so that occupants cannot put hats on themselves.

## 7. Ad-hoc Commands (optional)

A room MAY extend the XEP-0317 ad-hoc commands with the following two commands.
Both are restricted to the same entities that may manage hats in the room.

* `urn:xmpp:scoped-hats:commands:assign`, a form with the fields
  `hats#jid` (jid-single, the wearer), `hats#uri` (text-single, a hat defined in the room),
  `hats#audience` (jid-multi, required, at least one JID) and `hats#mutual` (boolean, default false).
* `urn:xmpp:scoped-hats:commands:remove`, a form with the fields
  `hats#jid`, `hats#uri`, `hats#audience` (jid-multi, optional, empty means every viewer)
  and `hats#mutual`.

The command node `urn:xmpp:scoped-hats:commands:list` MAY return the room's scoped hat assignments
to the same entities. Implementations SHOULD NOT expose that list to occupants who are not room administrators,
because it reveals every audience.

## 8. Business Rules

1. A scoped assignment MUST reference a hat defined in the room (XEP-0317).
   Removing that hat from the room removes all of its assignments, room-wide and scoped.
2. The audience MUST NOT be empty, and MUST NOT contain the wearer.
3. A room SHOULD require the wearer and every viewer to have an affiliation of member or higher,
   and SHOULD remove scoped assignments when the affiliation of either party is removed.
   This keeps a recycled account from inheriting a relationship it was never part of.
4. Assigning a scoped hat that already exists is not an error and changes nothing.
5. Redefining a hat (a new title or hue) applies to its scoped assignments as well.
6. Assignments are keyed by bare JIDs, and persist with the room like XEP-0317 hats.
   They are not tied to nicknames, so they survive nick changes and reconnections.
7. A service MAY limit the audience size or the number of scoped assignments per room.

## 9. Discovering Support

A room that implements this specification MUST advertise the `urn:xmpp:scoped-hats:0` feature
in its disco#info response, next to `urn:xmpp:hats:0`:

```xml
<iq from='party@chat.example.com' to='romeo@example.net/orchard' type='result' id='disco1'>
  <query xmlns='http://jabber.org/protocol/disco#info'>
    <identity category='conference' type='text' name='Party'/>
    <feature var='http://jabber.org/protocol/muc'/>
    <feature var='urn:xmpp:hats:0'/>
    <feature var='urn:xmpp:scoped-hats:0'/>
  </query>
</iq>
```

Clients MUST ignore `<scoped-hats/>` elements from rooms that do not advertise the feature (see Section 11).

## 10. Backward Compatibility

* Clients that do not implement this specification ignore the `<scoped-hats/>` element,
  as XMPP requires for unknown extension elements. They never display a scoped hat,
  including clients that implement XEP-0317, because scoped hats are never placed in `<hats/>`.
* Occupants outside the audience receive exactly the presences they would receive without this
  specification, so their clients are not affected in any way.
* Rooms that implement only XEP-0317 are not affected, and a client can tell from disco#info
  whether scoped hats are in use.

## 11. Security Considerations

1. **Forgery.** A room that does not implement this specification passes client extension elements through,
   so an occupant could send a forged `<scoped-hats/>` element that other occupants receive.
   Clients MUST only display scoped hats from rooms that advertise `urn:xmpp:scoped-hats:0`,
   and those rooms MUST strip client-provided elements (Section 6.4). The same is true of XEP-0317 hats.
2. **Authority.** Only room administrators (or the service) may assign scoped hats.
   A scoped hat often signals a relationship ("Your match", "Your host") that a viewer may act on,
   so assignment rights should be at least as strict as for room-wide hats.
3. **Stale relationships.** Removing assignments together with affiliations (Business Rule 3) prevents
   a deleted and re-registered account from appearing in an old relationship.

## 12. Privacy Considerations

1. **No audience disclosure.** The wire format never names the audience, so a viewer cannot learn who
   else sees a hat, and no occupant learns real JIDs it could not see before, even in semi-anonymous rooms.
2. **No side channel to non-viewers.** Rooms send presence updates caused by scoped hats only to the
   affected viewers (Section 6.3). A room that broadcast the updated presence to everyone would let
   other occupants infer, from an unchanged presence arriving, that a hidden change happened.
3. **The wearer may not be told.** A wearer does not receive its own scoped hats (Section 6.2). For
   relationships the wearer must be aware of, use a pairwise hat, so that each party sees the hat on the other.
4. **Hat definitions are room-wide.** Hat URIs and titles are defined for the whole room. A room that
   lets occupants list hat definitions (for example through XEP-0317 commands) reveals that a hat
   such as "Your match" exists. Services should restrict such lists to administrators when titles are sensitive.
5. **Archives.** Presences are not archived by XEP-0313, so scoped hats do not leak through message archives.
   Services that log presences must treat scoped hats as private to the audience.
6. **Administrative access.** Room administrators can see all assignments. Services should treat
   the assignment list as personal data where it describes relationships between people.

## 13. Implementation Notes (MongooseIM)

MongooseIM implements this specification in `mod_muc`:

* Enable it with `scoped_hats = true` together with `hats = true` in the `modules.mod_muc` section.
* Scoped hats are managed with the admin GraphQL API in the `muc` category:
  `assignScopedRoomHat(room, user, uri, audience, mutual)` and
  `unassignScopedRoomHat(room, user, uri, audience, mutual)`,
  and `listRoomHats` returns them in `scopedAssignments` (one entry per wearer and viewer).
* The wearer and every viewer need an affiliation (member or higher), and assignments are removed
  with the affiliation of either party.
* The optional ad-hoc commands of Section 7 are not implemented.
* Assignments are stored with the room options, so they persist with persistent rooms,
  in both the RDBMS and Mnesia backends.

## 14. IANA Considerations

None.

## 15. XMPP Registrar Considerations

The XMPP Registrar would include `urn:xmpp:scoped-hats:0` in its registry of protocol namespaces,
and the commands `urn:xmpp:scoped-hats:commands:assign`, `urn:xmpp:scoped-hats:commands:remove`
and `urn:xmpp:scoped-hats:commands:list` in its registry of ad-hoc command nodes, if the optional commands are kept.

## 16. XML Schema

```xml
<?xml version='1.0' encoding='UTF-8'?>
<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema'
           targetNamespace='urn:xmpp:scoped-hats:0'
           xmlns='urn:xmpp:scoped-hats:0'
           elementFormDefault='qualified'>

  <xs:element name='scoped-hats'>
    <xs:complexType>
      <xs:sequence>
        <xs:element ref='hat' minOccurs='1' maxOccurs='unbounded'/>
      </xs:sequence>
    </xs:complexType>
  </xs:element>

  <xs:element name='hat'>
    <xs:complexType>
      <xs:attribute name='uri' type='xs:anyURI' use='required'/>
      <xs:attribute name='title' type='xs:string' use='required'/>
      <xs:attribute name='hue' use='optional'>
        <xs:simpleType>
          <xs:restriction base='xs:decimal'>
            <xs:minInclusive value='0'/>
            <xs:maxExclusive value='360'/>
          </xs:restriction>
        </xs:simpleType>
      </xs:attribute>
    </xs:complexType>
  </xs:element>

</xs:schema>
```

## 17. Open Questions

1. Should a wearer be able to learn its own scoped hats, for example in its self-presence
   (XEP-0045 status 110) with an indication of how many viewers see each hat?
   This draft says no, and recommends pairwise hats when both parties must know.
2. Should the assignment protocol use XEP-0421 occupant identifiers in addition to bare JIDs,
   so that rooms with anonymous occupants can scope hats without revealing real JIDs to administrators?
3. Should scoped hats also be available to MUC Light or MIX channels?
