import SwiftUI
import UniformTypeIdentifiers

// MARK: - ExpenditureView  (F-048)
//
// Approximate personal-expenditure tracker over the F-044 synced SMS. Month summary
// (spent/received/net), spend-by-category, and a transaction list with source-SMS
// drill-in + re-categorize/exclude overrides. "Approximate" is stated plainly — every
// figure traces back to its SMS (D11).

struct ExpenditureView: View {
    @StateObject private var vm = ExpenditureViewModel()
    @State private var passphrase = ""
    @State private var expandedId: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.haloBorder)
            content
        }
        .background(Color.haloSurface)
        .onAppear { vm.autoConnect() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "indianrupeesign.circle.fill").foregroundColor(.haloGreen)
            Text("Expenditure").font(HaloFont.display(18)).foregroundColor(.haloText)
            HaloBadge(text: "Approximate", color: .haloAmber)
            Spacer()
            if case .connected = vm.state {
                HStack(spacing: 10) {
                    Button { vm.stepMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                    Text(vm.monthLabel).font(HaloFont.body(13, weight: .semibold)).foregroundColor(.haloText)
                        .frame(width: 130)
                    Button { vm.stepMonth(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).disabled(vm.isCurrentMonth)
                }
                .foregroundColor(.haloText2)
                Button { exportCSV() } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.plain).foregroundColor(.haloText2)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if !vm.isConfigured {
            notConfigured
        } else if case .connected = vm.state {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCards
                    if !vm.categoryBreakdown.isEmpty { categorySection }
                    transactionsSection
                }
                .padding(20)
            }
        } else {
            connectPrompt
        }
    }

    private var notConfigured: some View {
        emptyState("externaldrive.badge.icloud", "Connect your Firebase first",
                   "The tracker reads the transaction SMS synced by the Messages module. Set up cloud sync there, then come back.")
    }

    private var connectPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundColor(.haloAccent)
            Text("Unlock your synced messages").font(HaloFont.display(16)).foregroundColor(.haloText)
            Text("Enter your encryption passphrase to parse transactions on this Mac.")
                .font(HaloFont.body(12)).foregroundColor(.haloText2).multilineTextAlignment(.center)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.plain).font(HaloFont.body(12)).foregroundColor(.haloText)
                .padding(8).frame(width: 260).background(Color.haloSurface2).cornerRadius(7)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.haloBorder, lineWidth: 1))
            HaloPrimaryButton("Unlock", icon: "key") {
                vm.connect(passphrase: passphrase); passphrase = ""
            }.disabled(passphrase.isEmpty)
            if case .error(let m) = vm.state {
                Text(m).font(HaloFont.body(11)).foregroundColor(.haloRed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Summary

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard("Spent", vm.spent, .haloRed, "arrow.up.right")
            summaryCard("Received", vm.received, .haloGreen, "arrow.down.left")
            summaryCard("Net", vm.net, vm.net >= 0 ? .haloGreen : .haloRed, "equal.circle")
        }
    }

    private func summaryCard(_ title: String, _ amount: Double, _ color: Color, _ icon: String) -> some View {
        HaloCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 11)).foregroundColor(color)
                    Text(title).font(HaloFont.body(11, weight: .semibold)).foregroundColor(.haloText2)
                }
                Text(ExpenditureViewModel.formatINR(amount))
                    .font(HaloFont.display(20)).foregroundColor(.haloText).lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Category breakdown

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SPEND BY CATEGORY").font(HaloFont.body(10, weight: .semibold)).foregroundColor(.haloText2)
            let max = vm.categoryBreakdown.first?.amount ?? 1
            ForEach(vm.categoryBreakdown, id: \.category) { row in
                Button { vm.selectedCategory = vm.selectedCategory == row.category ? nil : row.category } label: {
                    HStack(spacing: 10) {
                        Text(row.category).font(HaloFont.body(12)).foregroundColor(.haloText).frame(width: 130, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.haloSurface2)
                                Capsule().fill(categoryColor(row.category))
                                    .frame(width: geo.size.width * CGFloat(row.amount / max))
                            }
                        }
                        .frame(height: 14)
                        Text(ExpenditureViewModel.formatINR(row.amount))
                            .font(HaloFont.body(11)).foregroundColor(.haloText2).frame(width: 90, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                    .opacity(vm.selectedCategory == nil || vm.selectedCategory == row.category ? 1 : 0.4)
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: Transactions

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TRANSACTIONS").font(HaloFont.body(10, weight: .semibold)).foregroundColor(.haloText2)
                if let cat = vm.selectedCategory {
                    HaloBadge(text: cat, color: categoryColor(cat))
                    Button { vm.selectedCategory = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundColor(.haloText3)
                }
                Spacer()
                if vm.unreadableCount > 0 {
                    Text("\(vm.unreadableCount) unreadable").font(HaloFont.body(10)).foregroundColor(.haloAmber)
                }
            }
            if vm.displayedTransactions.isEmpty {
                Text("No transactions parsed for this month.")
                    .font(HaloFont.body(12)).foregroundColor(.haloText2).padding(.vertical, 20)
            } else {
                ForEach(vm.displayedTransactions) { txn in transactionRow(txn) }
            }
        }
    }

    private func transactionRow(_ txn: ParsedTransaction) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(categoryColor(txn.category).opacity(0.18)).frame(width: 32, height: 32)
                    Image(systemName: txn.isTransfer ? "arrow.left.arrow.right"
                                        : txn.direction.isExpense ? "arrow.up.right" : "arrow.down.left")
                        .font(.system(size: 12)).foregroundColor(categoryColor(txn.category))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(txn.merchant ?? txn.sender).font(HaloFont.body(12, weight: .semibold))
                        .foregroundColor(.haloText).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(txn.category).font(HaloFont.body(10)).foregroundColor(.haloText2)
                        if let acct = txn.accountHint { Text("· \(acct)").font(HaloFont.body(10)).foregroundColor(.haloText3) }
                        if txn.isDuplicate { HaloBadge(text: "dup", color: .haloText3) }
                        if txn.forceIncluded { HaloBadge(text: "＋", color: .haloAccent) }
                        if txn.confidence < 0.7 { Image(systemName: "questionmark.circle").font(.system(size: 9)).foregroundColor(.haloAmber) }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text((txn.direction.isExpense ? "-" : "+") + ExpenditureViewModel.formatINR(txn.amount))
                        .font(HaloFont.body(13, weight: .semibold))
                        .foregroundColor(txn.isTransfer ? .haloText2 : txn.direction.isExpense ? .haloRed : .haloGreen)
                        .strikethrough(txn.isTransfer || txn.isDuplicate)
                    Text(dateShort(txn.date)).font(HaloFont.body(10)).foregroundColor(.haloText3)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onTapGesture { expandedId = expandedId == txn.id ? nil : txn.id }

            if expandedId == txn.id { drillIn(txn) }
        }
        .background(Color.haloSurface2.opacity(expandedId == txn.id ? 0.5 : 0)).cornerRadius(8)
    }

    private func drillIn(_ txn: ParsedTransaction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SOURCE SMS · \(txn.sender)").font(HaloFont.body(9, weight: .semibold)).foregroundColor(.haloText3)
            Text(txn.body).font(HaloFont.body(11)).foregroundColor(.haloText2).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Menu {
                    ForEach(vm.categoryNames, id: \.self) { c in
                        Button(c) { vm.recategorize(txn, to: c) }
                    }
                } label: {
                    Label("Category", systemImage: "tag").font(HaloFont.body(11))
                }.menuStyle(.borderlessButton).fixedSize()
                Button { vm.exclude(txn) } label: {
                    Label("Exclude", systemImage: "minus.circle").font(HaloFont.body(11)).foregroundColor(.haloRed)
                }.buttonStyle(.plain)
                Spacer()
                Text(String(format: "confidence %.0f%%", txn.confidence * 100))
                    .font(HaloFont.body(10)).foregroundColor(.haloText3)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    // MARK: Helpers

    private func emptyState(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38)).foregroundColor(.haloAccent)
            Text(title).font(HaloFont.display(16)).foregroundColor(.haloText)
            Text(subtitle).font(HaloFont.body(12)).foregroundColor(.haloText2)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dateShort(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f.string(from: d)
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "Food & Dining": return .haloAmber
        case "Groceries": return .haloGreen
        case "Shopping": return .haloAccent
        case "Bills & Utilities": return .haloCyan
        case "Transport": return .haloPurple
        case "Entertainment": return .haloRed
        case "Health": return Color(hex: "#22d97a")
        case "Financial": return .haloAccent2
        case "Income": return .haloGreen
        case "Transfers": return .haloText2
        default: return .haloText3
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "halo-expenditure.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? vm.exportCSV().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
