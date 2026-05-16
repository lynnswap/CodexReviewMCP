extension CodexReviewStore {
    package var orderedWorkspaces: [CodexReviewWorkspace] {
        workspaces.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.cwd < $1.cwd
            }
            return $0.sortOrder < $1.sortOrder
        }
    }
}

package func reorderedSortOrder<Item: AnyObject>(
    moving item: Item,
    toIndex destinationIndex: Int,
    in orderedItems: [Item],
    sortOrder: (Item) -> Double
) -> Double? {
    guard let sourceIndex = orderedItems.firstIndex(where: { $0 === item }) else {
        return nil
    }

    var remainingItems = orderedItems
    remainingItems.remove(at: sourceIndex)
    let insertionIndex = max(0, min(destinationIndex, remainingItems.count))
    let previousSortOrder = insertionIndex > 0
        ? sortOrder(remainingItems[insertionIndex - 1])
        : nil
    let nextSortOrder = insertionIndex < remainingItems.count
        ? sortOrder(remainingItems[insertionIndex])
        : nil

    switch (previousSortOrder, nextSortOrder) {
    case (.some(let previous), .some(let next)):
        return (previous + next) / 2
    case (.some(let previous), .none):
        return previous + 1
    case (.none, .some(let next)):
        return next - 1
    case (.none, .none):
        return 0
    }
}
