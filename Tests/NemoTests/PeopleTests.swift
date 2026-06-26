import XCTest
@testable import Nemo

final class PersonModelTests: XCTestCase {

    func testKnownNamesLowercasesCanonicalAndAliases() {
        let p = Person(name: "Priya Shah", aliases: ["Priya", "P. Shah"])
        XCTAssertEqual(Set(p.knownNames), ["priya shah", "priya", "p. shah"])
    }

    func testFirstName() {
        XCTAssertEqual(Person(name: "Sarah Chen").firstName, "Sarah")
        XCTAssertEqual(Person(name: "Madonna").firstName, "Madonna")
    }

    func testAttributeLineComposesRoleOrgEmail() {
        var p = Person(name: "Dana")
        p.attributes = ["role": "PM", "org": "Acme", "email": "dana@acme.com"]
        XCTAssertEqual(p.attributeLine, "PM at Acme · dana@acme.com")
    }

    func testAttributeLineOrgOnly() {
        var p = Person(name: "Dana")
        p.attributes = ["org": "Acme"]
        XCTAssertEqual(p.attributeLine, "Acme")
    }

    func testDisplaySummaryPrefersUserEditedText() {
        var p = Person(name: "Dana", summary: "My manager.", userEdited: true)
        p.facts = [PersonFact(text: "Likes async updates")]
        XCTAssertEqual(p.displaySummary, "My manager.")
    }

    func testDisplaySummaryDerivesFromFactsWhenNoSummary() {
        var p = Person(name: "Dana")
        p.attributes = ["role": "PM"]
        p.facts = [PersonFact(text: "Leads onboarding")]
        XCTAssertTrue(p.displaySummary.contains("PM"))
        XCTAssertTrue(p.displaySummary.contains("Leads onboarding"))
    }

    func testFactDedupKeyNormalizesPunctuationAndCase() {
        let a = PersonFact(text: "Leads the Onboarding project!")
        let b = PersonFact(text: "leads the onboarding project")
        XCTAssertEqual(a.dedupKey, b.dedupKey)
    }
}

final class PeopleBuilderTests: XCTestCase {

    private func mem(_ title: String, category: Nemo.Category = .people,
                     entities: [String] = []) -> Memory {
        Memory(title: title, content: "note", category: category.rawValue, entities: entities)
    }

    func testReferencedNamesCollectsEntitiesLowercased() {
        let names = PeopleBuilder.referencedNames(in: [
            mem("a", entities: ["Priya Shah", "Acme"]),
            mem("b", entities: ["Sarah"])
        ])
        XCTAssertTrue(names.contains("priya shah"))
        XCTAssertTrue(names.contains("sarah"))
    }

    func testHasCandidatesTrueForPeopleCategoryOrEntities() {
        XCTAssertTrue(PeopleBuilder.hasCandidates(in: [mem("x", category: .people)]))
        XCTAssertTrue(PeopleBuilder.hasCandidates(in: [mem("x", category: .facts, entities: ["Tom"])]))
        XCTAssertFalse(PeopleBuilder.hasCandidates(in: [mem("x", category: .facts, entities: [])]))
    }

    func testDeterministicResolveCreatesNewPersonFromPeopleEntity() {
        let people = PeopleBuilder.resolveDeterministically(
            touched: [mem("Met Priya", entities: ["Priya Shah"])], existing: [])
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0].name, "Priya Shah")
        XCTAssertEqual(people[0].mentionCount, 1)
    }

    func testDeterministicResolveAttachesToExistingExactName() {
        let m = mem("Priya again", entities: ["Priya Shah"])
        let existing = [Person(name: "Priya Shah", mentionCount: 1)]
        let people = PeopleBuilder.resolveDeterministically(touched: [m], existing: existing)
        XCTAssertEqual(people.count, 1, "exact-name match should attach, not duplicate")
        XCTAssertEqual(people[0].mentionCount, 2)
        XCTAssertTrue(people[0].memoryIds.contains(m.id))
    }

    func testDeterministicResolveDoesNotMergeDifferentNames() {
        // Two different names must stay two different people — never assume sameness.
        let existing = [Person(name: "Sarah Chen", mentionCount: 1)]
        let people = PeopleBuilder.resolveDeterministically(
            touched: [mem("New Sarah", entities: ["Sarah Patel"])], existing: existing)
        XCTAssertEqual(people.count, 2)
        XCTAssertEqual(Set(people.map(\.name)), ["Sarah Chen", "Sarah Patel"])
    }

    func testDeterministicResolveIgnoresNonPeopleCategoryEntities() {
        // A project entity in a non-People memory shouldn't become a person in the safe fallback.
        let people = PeopleBuilder.resolveDeterministically(
            touched: [mem("Project kickoff", category: .projects, entities: ["Acme Migration"])],
            existing: [])
        XCTAssertTrue(people.isEmpty)
    }
}
