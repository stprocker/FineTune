// FineTune/Views/Components/DropdownMenu.swift
import SwiftUI

// MARK: - Shared Trigger Button

/// Shared trigger button used by both DropdownMenu and GroupedDropdownMenu.
/// Extracts ~40 lines of identical trigger button code into one component.
struct DropdownTriggerButton<Label: View>: View {
    @Binding var isExpanded: Bool
    let width: CGFloat
    @ViewBuilder let label: () -> Label

    @State private var isButtonHovered = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                label()
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 4)
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                .strokeBorder(
                    isButtonHovered ? Color.white.opacity(0.35) : Color.white.opacity(0.2),
                    lineWidth: 0.5
                )
        }
        .onHover { isButtonHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isButtonHovered)
    }
}

// MARK: - Dropdown Menu

/// A reusable dropdown menu component with height restriction support
struct DropdownMenu<Item: Identifiable, Label: View, ItemContent: View>: View where Item.ID: Hashable {
    let items: [Item]
    let selectedItem: Item?
    let maxVisibleItems: Int?
    let width: CGFloat
    let popoverWidth: CGFloat?
    let onSelect: (Item) -> Void
    @ViewBuilder let label: (Item?) -> Label
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    @State private var isExpanded = false

    // Configuration
    private let itemHeight: CGFloat = 20
    private let cornerRadius: CGFloat = 8
    private let animationDuration: Double = 0.15

    private var effectivePopoverWidth: CGFloat {
        popoverWidth ?? width
    }

    private var menuHeight: CGFloat {
        let itemCount = CGFloat(items.count)
        if let max = maxVisibleItems {
            return min(itemCount, CGFloat(max)) * itemHeight + 10
        }
        return itemCount * itemHeight + 10
    }

    var body: some View {
        DropdownTriggerButton(isExpanded: $isExpanded, width: width) {
            label(selectedItem)
        }
        .background(
            PopoverHost(isPresented: $isExpanded) {
                DropdownContentView(
                    items: items,
                    selectedItem: selectedItem,
                    width: effectivePopoverWidth,
                    menuHeight: menuHeight,
                    itemHeight: itemHeight,
                    cornerRadius: cornerRadius,
                    onSelect: { item in
                        onSelect(item)
                        withAnimation(.easeOut(duration: animationDuration)) {
                            isExpanded = false
                        }
                    },
                    itemContent: itemContent
                )
            }
        )
    }
}

// MARK: - Dropdown Content View

private struct DropdownContentView<Item: Identifiable, ItemContent: View>: View where Item.ID: Hashable {
    let items: [Item]
    let selectedItem: Item?
    let width: CGFloat
    let menuHeight: CGFloat
    let itemHeight: CGFloat
    let cornerRadius: CGFloat
    let onSelect: (Item) -> Void
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(items) { item in
                    DropdownMenuItem(
                        item: item,
                        isSelected: selectedItem?.id == item.id,
                        itemHeight: itemHeight,
                        onSelect: onSelect,
                        itemContent: itemContent
                    )
                    .id(item.id)
                }
            }
            .padding(5)
            .scrollTargetLayout()
        }
        .scrollPosition(id: .constant(selectedItem?.id), anchor: .center)
        .frame(width: width, height: menuHeight)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }
}

// MARK: - Dropdown Menu Item (with hover tracking)

private struct DropdownMenuItem<Item: Identifiable, ItemContent: View>: View where Item.ID: Hashable {
    let item: Item
    let isSelected: Bool
    let itemHeight: CGFloat
    let onSelect: (Item) -> Void
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect(item)
        } label: {
            itemContent(item, isSelected)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .frame(height: itemHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .whenHovered { isHovered = $0 }
    }
}

// MARK: - Grouped Dropdown Menu

/// A dropdown menu with section headers for grouped/categorized items
struct GroupedDropdownMenu<Section: Identifiable & Hashable, Item: Identifiable, Label: View, ItemContent: View>: View
    where Item.ID: Hashable {

    let sections: [Section]
    let itemsForSection: (Section) -> [Item]
    let sectionTitle: (Section) -> String
    let selectedItem: Item?
    let maxHeight: CGFloat
    let width: CGFloat
    let popoverWidth: CGFloat?
    let onSelect: (Item) -> Void
    @ViewBuilder let label: (Item?) -> Label
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    @State private var isExpanded = false

    // Configuration
    private let itemHeight: CGFloat = 22
    private let sectionHeaderHeight: CGFloat = 24
    private let cornerRadius: CGFloat = 8
    private let animationDuration: Double = 0.15

    private var effectivePopoverWidth: CGFloat {
        popoverWidth ?? width
    }

    var body: some View {
        DropdownTriggerButton(isExpanded: $isExpanded, width: width) {
            label(selectedItem)
        }
        .background(
            PopoverHost(isPresented: $isExpanded) {
                GroupedDropdownContentView(
                    sections: sections,
                    itemsForSection: itemsForSection,
                    sectionTitle: sectionTitle,
                    selectedItem: selectedItem,
                    width: effectivePopoverWidth,
                    maxHeight: maxHeight,
                    itemHeight: itemHeight,
                    sectionHeaderHeight: sectionHeaderHeight,
                    cornerRadius: cornerRadius,
                    onSelect: { item in
                        onSelect(item)
                        withAnimation(.easeOut(duration: animationDuration)) {
                            isExpanded = false
                        }
                    },
                    itemContent: itemContent
                )
            }
        )
    }
}

// MARK: - Grouped Dropdown Content View

private struct GroupedDropdownContentView<Section: Identifiable & Hashable, Item: Identifiable, ItemContent: View>: View
    where Item.ID: Hashable {

    let sections: [Section]
    let itemsForSection: (Section) -> [Item]
    let sectionTitle: (Section) -> String
    let selectedItem: Item?
    let width: CGFloat
    let maxHeight: CGFloat
    let itemHeight: CGFloat
    let sectionHeaderHeight: CGFloat
    let cornerRadius: CGFloat
    let onSelect: (Item) -> Void
    @ViewBuilder let itemContent: (Item, Bool) -> ItemContent

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    // Section header
                    Text(sectionTitle(section))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, section.id == sections.first?.id ? 2 : 8)
                        .padding(.bottom, 2)
                        .frame(height: sectionHeaderHeight, alignment: .bottomLeading)

                    // Items in section
                    ForEach(itemsForSection(section)) { item in
                        DropdownMenuItem(
                            item: item,
                            isSelected: selectedItem?.id == item.id,
                            itemHeight: itemHeight,
                            onSelect: onSelect,
                            itemContent: itemContent
                        )
                    }
                }
            }
            .padding(5)
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .background(
            VisualEffectBackground(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(DesignTokens.Colors.glassBorder, lineWidth: 0.5)
        }
    }
}
