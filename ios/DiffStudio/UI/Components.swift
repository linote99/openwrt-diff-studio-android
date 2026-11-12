// Components.swift
// Shared SwiftUI pieces mirroring MainActivity's programmatic widgets:
// heading(), stat(), details(), errorBox(), noticeBox().

import SwiftUI

public struct HeadingView: View {
    public let number: String
    public let title: String
    public init(number: String, title: String) {
        self.number = number
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(title)
                .font(.system(size: 17, weight: .bold))
        }
    }
}

public struct StatView: View {
    public let value: String
    public let caption: String
    public init(value: String, caption: String) {
        self.value = value
        self.caption = caption
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold))
            Text(caption).font(.system(size: 12)).foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

public struct DetailsView: View {
    public let summary: String
    public let detailText: String
    @State private var open = false
    public init(summary: String, body: String) {
        self.summary = summary
        self.detailText = body
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(detailText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } label: {
            Text((open ? "▾ " : "▸ ") + summary)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }
}

public struct ErrorBoxView: View {
    public let raw: String
    @EnvironmentObject private var state: AppState
    public init(raw: String) { self.raw = raw }

    public var body: some View {
        let result = ErrorExplain.explain(raw, english: state.english)
        VStack(alignment: .leading, spacing: 8) {
            Text("⚠  " + result.message)
                .font(.system(size: 14))
                .foregroundColor(.red)
            DetailsView(summary: state.tr("Technical details"), body: result.details)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 12)
    }
}

public struct NoticeBoxView: View {
    public let message: String
    public let spinner: Bool
    public let small: String?
    @EnvironmentObject private var state: AppState
    public init(message: String, spinner: Bool = false, small: String? = nil) {
        self.message = message
        self.spinner = spinner
        self.small = small
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if spinner {
                ProgressView().frame(width: 20, height: 20)
            } else {
                Text("✓").font(.system(size: 15, weight: .bold)).foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.system(size: 14))
                if let small {
                    Text(small).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 12)
    }
}

public struct CardView<Content: View>: View {
    public let content: Content
    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(.separator).opacity(0.4), lineWidth: 1))
    }
}

public struct PickerButton: View {
    public let value: String
    public let placeholder: String
    public let action: () -> Void
    public init(value: String, placeholder: String, action: @escaping () -> Void) {
        self.value = value
        self.placeholder = placeholder
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(value.isEmpty ? placeholder : value)
                .font(.system(size: 14))
                .foregroundColor(value.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .padding(.horizontal, 14)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator).opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}

public struct SectionLabel: View {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.top, 14)
    }
}
