import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct EntryEditorSheet: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let editingEntry: JournalEntry?
    var draft: SOTDDraft? = nil
    var initialDate: Date? = nil
    var onSaved: ((JournalEntry) -> Void)? = nil

    // AI 一句话自然语言快速填表
    @State private var naturalInput: String = ""
    @State private var isParsingNatural: Bool = false
    @State private var naturalStatusMessage: String? = nil
    @State private var naturalStatusIsError: Bool = false

    // AI 拍照 / 传图识别 SOTD 装备
    @State private var selectedPhotoImage: NSImage? = nil
    @State private var selectedPhotoDataURL: String? = nil
    @State private var selectedPhotoLabel: String = ""
    @State private var isPhotoDropTargeted: Bool = false
    @State private var isRecognizingPhoto: Bool = false
    @State private var photoStatusMessage: String? = nil
    @State private var photoStatusIsError: Bool = false
    @State private var photoStatusIsWarning: Bool = false
    @State private var pasteEventMonitor: Any? = nil

    @State private var date: Date = Date()
    @State private var razor: String = ""
    @State private var bladeBase: String = ""
    @State private var bladeUseCount: Int = 1
    @State private var brush: String = ""
    @State private var soap: String = ""
    @State private var bowlName: String = ""
    @State private var preShave: String = ""
    @State private var afterShave: String = ""

    @State private var loadingMethod: SoapLoadingMethod = .brushLoad
    @State private var latheringMode: LatheringMethod = .bowl
    @State private var afterShower: Bool = true
    @State private var hotTowel: Bool = false
    @State private var useAlum: Bool = true

    @State private var selectedPasses: [ShavePassType: String] = [
        .wtg: "",
        .atg: "",
        .pickup: ""
    ]
    @State private var shaveResult: ShaveResult = .bbs
    @State private var irritation: IrritationLevel = .painless
    @State private var processNote: String = ""
    @State private var saveErrorMessage: String? = nil
    @State private var selectedGearBindings: [GearCategory: (text: String, item: GearItem)] = [:]

    private var isAdjustableRazor: Bool {
        store.isRazorAdjustable(razor)
    }

    var body: some View {
        let _ = store.language
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                Text(editingEntry == nil ? L10n.t("记录今日 SOTD", "New SOTD") : L10n.t("编辑 SOTD", "Edit SOTD"))
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                DatePicker(L10n.t("日期", "Date"), selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // AI 功能 ②：一句话自然语言快速记 SOTD
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            HStack(spacing: 7) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 13))
                                    .foregroundStyle(ShaveTheme.accent)
                                TextField(
                                    L10n.t(
                                        "一句话快速记 SOTD：如「浴后热敷，黑鸟钛配俄纸第2次，Shavemac 26刷，MDC苦艾Fizz碗起，顺逆补无痛BBS」",
                                        "Quick SOTD sentence: e.g., Post-shower hot towel, Blackbird Ti + Nacet 2nd, Shavemac 26mm, MDC Absinthe bowl lather, WTG/ATG/Pickup painless BBS"
                                    ),
                                    text: $naturalInput
                                )
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .onSubmit {
                                    if !naturalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isParsingNatural {
                                        Task { await runNaturalLanguageParse() }
                                    }
                                }
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8.5)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ShaveTheme.cardBackground(scheme)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ShaveTheme.accent.opacity(0.32), lineWidth: 1))

                            Button {
                                Task { await runNaturalLanguageParse() }
                            } label: {
                                HStack(spacing: 5) {
                                    if isParsingNatural {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(isParsingNatural ? L10n.t("解析中...", "Parsing...") : L10n.t("AI 解析填表", "AI Parse"))
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ShaveTheme.accent)
                            .disabled(isParsingNatural || naturalInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if let msg = naturalStatusMessage {
                            Text(msg)
                                .font(.system(size: 12))
                                .foregroundStyle(naturalStatusIsError ? ShaveTheme.amber : ShaveTheme.forest)
                                .padding(.leading, 4)
                        }
                    }

                    // AI 功能 ②-B：📷 拍照 / 传图识别 SOTD 装备（支持选择文件、拖拽照片、⌘+V 剪贴板粘贴）
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            if let preview = selectedPhotoImage {
                                Image(nsImage: preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(L10n.t("📷 拍照 / 传图识别", "📷 Photo / Image AI Recognition"))
                                            .font(.system(size: 13, weight: .semibold))
                                        if !selectedPhotoLabel.isEmpty {
                                            Text(selectedPhotoLabel)
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Text(L10n.t(
                                        "已自动压缩至长边 ≤ 1280px JPEG · 可继续拖入新照片或按 ⌘V 替换",
                                        "Compressed to ≤ 1280px JPEG · Drop another photo or press ⌘V to replace"
                                    ))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.tertiary)
                                }

                                Spacer(minLength: 8)

                                HStack(spacing: 8) {
                                    Button {
                                        Task { await runPhotoRecognition() }
                                    } label: {
                                        HStack(spacing: 5) {
                                            if isRecognizingPhoto {
                                                ProgressView().controlSize(.small)
                                            } else {
                                                Image(systemName: "sparkles")
                                                    .font(.system(size: 12))
                                            }
                                            Text(isRecognizingPhoto
                                                ? L10n.t("识别中...", "Identifying...")
                                                : L10n.t("AI 识别装备", "Identify Gear"))
                                                .font(.system(size: 12.5, weight: .semibold))
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(ShaveTheme.accent)
                                    .disabled(isRecognizingPhoto || selectedPhotoDataURL == nil)

                                    Button {
                                        clearSelectedPhoto()
                                    } label: {
                                        Label(L10n.t("清除", "Clear"), systemImage: "xmark")
                                            .font(.system(size: 12.5))
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isRecognizingPhoto)
                                }
                            } else {
                                HStack(spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(ShaveTheme.accentSoft)
                                            .frame(width: 38, height: 38)
                                        Image(systemName: "camera.viewfinder")
                                            .font(.system(size: 17, weight: .medium))
                                            .foregroundStyle(ShaveTheme.accent)
                                    }

                                    VStack(alignment: .leading, spacing: 2.5) {
                                        Text(L10n.t("📷 拍照 / 传图识别 SOTD 装备", "📷 Photo / Image AI Gear Recognition"))
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(L10n.t(
                                            "点击选图、拖拽照片到此处，或直接按 ⌘V 粘贴剪贴板照片（自动优先匹配器材库）",
                                            "Click to pick, drag & drop a photo here, or press ⌘V to paste (matches your gear library)"
                                        ))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    pickPhotoFile()
                                }

                                Spacer(minLength: 8)

                                HStack(spacing: 7) {
                                    Button {
                                        pickPhotoFile()
                                    } label: {
                                        Label(L10n.t("选择照片", "Choose Photo"), systemImage: "photo.badge.plus")
                                            .font(.system(size: 12.5, weight: .medium))
                                    }
                                    .buttonStyle(.bordered)

                                    Button {
                                        _ = pastePhotoFromClipboard(showEmptyHint: true)
                                    } label: {
                                        Label(L10n.t("粘贴 (⌘V)", "Paste (⌘V)"), systemImage: "doc.on.clipboard")
                                            .font(.system(size: 12.5))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(isPhotoDropTargeted ? ShaveTheme.accentSoft : ShaveTheme.cardBackground(scheme))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(
                                    isPhotoDropTargeted ? ShaveTheme.accent : ShaveTheme.cardBorder(scheme),
                                    style: StrokeStyle(lineWidth: isPhotoDropTargeted ? 1.6 : 1, dash: selectedPhotoImage == nil ? [5, 4] : [])
                                )
                        )
                        .onDrop(of: [.fileURL, .image], isTargeted: $isPhotoDropTargeted) { providers in
                            handlePhotoDrop(providers: providers)
                        }

                        if let msg = photoStatusMessage {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: photoStatusIsError
                                    ? "exclamationmark.triangle.fill"
                                    : (photoStatusIsWarning ? "info.circle.fill" : "checkmark.circle.fill"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(photoStatusIsError
                                        ? ShaveTheme.crimson
                                        : (photoStatusIsWarning ? ShaveTheme.amber : ShaveTheme.forest))
                                    .padding(.top, 1)
                                Text(msg)
                                    .font(.system(size: 12))
                                    .foregroundStyle(photoStatusIsError
                                        ? ShaveTheme.crimson
                                        : (photoStatusIsWarning ? ShaveTheme.amber : ShaveTheme.forest))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 4)
                        }
                    }

                    // 1. 装备搭配
                    SectionCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(L10n.t("装备搭配", "Setup"))
                                .font(.system(size: 16, weight: .semibold))

                            GearAutocompleteField(
                                title: GearCategory.razor.singularName,
                                category: .razor,
                                text: $razor,
                                placeholder: L10n.t("搜索或输入剃须刀...", "Search or enter razor..."),
                                onSelectItem: { selected, inserted in
                                    selectedGearBindings[.razor] = (inserted, selected)
                                }
                            )

                            VStack(alignment: .leading, spacing: 8) {
                                GearAutocompleteField(
                                    title: GearCategory.blade.singularName,
                                    category: .blade,
                                    text: $bladeBase,
                                    placeholder: L10n.t("搜索或输入刀片...", "Search or enter blade..."),
                                    onSelectItem: { selected, inserted in
                                        selectedGearBindings[.blade] = (inserted, selected)
                                        bladeUseCount = store.suggestedNextUseCount(forBlade: inserted)
                                    }
                                )

                                HStack(spacing: 12) {
                                    Text(L10n.t("使用次数", "Use Count"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)

                                    Stepper(value: $bladeUseCount, in: 1...50) {
                                        Text(L10n.isEnglish ? L10n.ordinal(bladeUseCount) : "第 \(bladeUseCount) 次 (\(L10n.ordinal(bladeUseCount)))")
                                            .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(ShaveTheme.accent)
                                    }

                                    Button {
                                        bladeUseCount = 1
                                    } label: {
                                        Label(L10n.t("换新刀片 (1st)", "Fresh Blade (1st)"), systemImage: "arrow.counterclockwise")
                                            .font(.system(size: 12.5))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.leading, 2)
                            }

                            GearAutocompleteField(
                                title: GearCategory.brush.singularName,
                                category: .brush,
                                text: $brush,
                                placeholder: L10n.t("搜索或输入剃须刷...", "Search or enter brush..."),
                                onSelectItem: { selected, inserted in
                                    selectedGearBindings[.brush] = (inserted, selected)
                                }
                            )

                            HStack(alignment: .top, spacing: 14) {
                                GearAutocompleteField(
                                    title: GearCategory.soap.singularName,
                                    category: .soap,
                                    text: $soap,
                                    placeholder: L10n.t("搜索或输入剃须皂...", "Search or enter soap..."),
                                    onSelectItem: { selected, inserted in
                                        selectedGearBindings[.soap] = (inserted, selected)
                                    }
                                )
                                GearAutocompleteField(
                                    title: GearCategory.bowl.singularName,
                                    category: .bowl,
                                    text: $bowlName,
                                    placeholder: L10n.t("选填...", "Optional..."),
                                    onSelectItem: { selected, inserted in
                                        selectedGearBindings[.bowl] = (inserted, selected)
                                    }
                                )
                            }

                            HStack(alignment: .top, spacing: 14) {
                                GearAutocompleteField(
                                    title: GearCategory.preShave.singularName,
                                    category: .preShave,
                                    text: $preShave,
                                    placeholder: L10n.t("选填...", "Optional..."),
                                    onSelectItem: { selected, inserted in
                                        selectedGearBindings[.preShave] = (inserted, selected)
                                    }
                                )
                                GearAutocompleteField(
                                    title: GearCategory.afterShave.singularName,
                                    category: .afterShave,
                                    text: $afterShave,
                                    placeholder: L10n.t("选填...", "Optional..."),
                                    onSelectItem: { selected, inserted in
                                        selectedGearBindings[.afterShave] = (inserted, selected)
                                    }
                                )
                            }
                        }
                    }

                    // 2. 剃须流程
                    SectionCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(L10n.t("剃须流程", "Prep & Lather"))
                                .font(.system(size: 16, weight: .semibold))

                            HStack(spacing: 24) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.t("取皂方式", "Loading"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                    Picker("Loading", selection: $loadingMethod) {
                                        ForEach(SoapLoadingMethod.allCases) { m in
                                            Text(m.displayName).tag(m)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 260)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.t("起泡方式", "Lathering"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                    Picker("Lathering", selection: $latheringMode) {
                                        ForEach(LatheringMethod.allCases) { m in
                                            Text(m.shortDisplayName).tag(m)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 230)
                                }

                                Spacer()
                            }

                            HStack(spacing: 26) {
                                Toggle(L10n.t("热敷", "Hot Towel"), isOn: $hotTowel)
                                    .toggleStyle(.switch)
                                    .tint(ShaveTheme.accent)

                                Toggle(L10n.t("浴后", "Post-Shower"), isOn: $afterShower)
                                    .toggleStyle(.switch)
                                    .tint(ShaveTheme.accent)

                                Toggle(L10n.t("明矾", "Alum Block"), isOn: $useAlum)
                                    .toggleStyle(.switch)
                                    .tint(ShaveTheme.accent)
                            }
                            .font(.system(size: 13.5, weight: .medium))
                        }
                    }

                    // 3. 剃须过程与体验
                    SectionCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 10) {
                                Text(L10n.t("过程与体验", "Passes & Result"))
                                    .font(.system(size: 16, weight: .semibold))
                                if isAdjustableRazor {
                                    TagPill(text: L10n.t("可调刀", "Adjustable"), color: ShaveTheme.accent)
                                }
                            }

                            HStack(alignment: .top, spacing: 10) {
                                ForEach(ShavePassType.allCases) { pass in
                                    let isOn = selectedPasses[pass] != nil
                                    VStack(spacing: 7) {
                                        Button {
                                            if isOn {
                                                selectedPasses.removeValue(forKey: pass)
                                            } else {
                                                selectedPasses[pass] = ""
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                                    .font(.system(size: 13.5))
                                                Text(pass.displayName)
                                                    .font(.system(size: 14, weight: .semibold))
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 40)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(isOn ? ShaveTheme.accent : ShaveTheme.subtleSurface(scheme))
                                            )
                                            .foregroundStyle(isOn ? Color.white : .primary)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                        .contentShape(Rectangle())

                                        if isAdjustableRazor {
                                            if isOn {
                                                HStack(spacing: 5) {
                                                    Text(L10n.t("档位", "Set"))
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(.secondary)
                                                    TextField("5", text: Binding(
                                                        get: { selectedPasses[pass] ?? "" },
                                                        set: { selectedPasses[pass] = $0 }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(.system(size: 13, design: .monospaced))
                                                    .frame(width: 58)
                                                }
                                                .frame(height: 28)
                                            } else {
                                                Color.clear.frame(height: 28)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }

                            HStack(spacing: 24) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.t("剃须效果", "Closeness"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                    Picker("Closeness", selection: $shaveResult) {
                                        ForEach(ShaveResult.allCases) { r in
                                            Text(r.displayName).tag(r)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 250)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.t("刺激程度", "Comfort"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                    Picker("Comfort", selection: $irritation) {
                                        ForEach(IrritationLevel.allCases) { l in
                                            Text(l.displayName).tag(l)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 240)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.t("备注（选填）", "Notes (Optional)"))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                TextField(L10n.t("例如：有血点、泡沫偏干...", "e.g., weeper, dry lather..."), text: $processNote)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 13.5))
                            }
                        }
                    }
                }
                .padding(22)
            }

            Divider()

            if let errMsg = saveErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ShaveTheme.crimson)
                    Text(errMsg)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ShaveTheme.crimson)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
            }

            HStack {
                Spacer()
                Button(L10n.t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editingEntry == nil ? L10n.t("保存日记", "Save Entry") : L10n.t("更新日记", "Update Entry")) {
                    saveEntry()
                }
                .buttonStyle(.borderedProminent)
                .tint(ShaveTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(razor.trimmingCharacters(in: .whitespaces).isEmpty || store.isReadOnlyProtected)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: 780, height: 820)
        .onAppear {
            loadInitialValues()
            installPasteMonitor()
        }
        .onDisappear {
            removePasteMonitor()
        }
    }

    // MARK: - 拍照 / 传图多模态 AI 识别交互

    private func installPasteMonitor() {
        removePasteMonitor()
        pasteEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "v",
               hasClipboardImageWithoutPlainText() {
                _ = pastePhotoFromClipboard(showEmptyHint: false)
                return nil
            }
            return event
        }
    }

    private func removePasteMonitor() {
        if let monitor = pasteEventMonitor {
            NSEvent.removeMonitor(monitor)
            pasteEventMonitor = nil
        }
    }

    private func hasClipboardImageWithoutPlainText() -> Bool {
        let pb = NSPasteboard.general
        // 若剪贴板包含纯文本（且不是图片文件路径），优先让输入框正常粘贴文本
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           clipboardImageFileURL() == nil,
           pb.data(forType: .png) == nil,
           pb.data(forType: .tiff) == nil {
            return false
        }
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil {
            return true
        }
        return clipboardImageFileURL() != nil
    }

    private func clipboardImageFileURL() -> URL? {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return nil
        }
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "tiff", "tif", "gif", "bmp"]
        return urls.first(where: { imageExts.contains($0.pathExtension.lowercased()) })
    }

    private func pickPhotoFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .tiff, .gif, .bmp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = L10n.t("选择 SOTD 照片", "Choose SOTD Photo")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let img = NSImage(contentsOf: url) else {
            photoStatusIsError = true
            photoStatusIsWarning = false
            photoStatusMessage = L10n.t("无法读取所选图片文件", "Could not load the selected image file")
            return
        }
        acceptSelectedPhoto(img, label: url.lastPathComponent)
    }

    @discardableResult
    private func pastePhotoFromClipboard(showEmptyHint: Bool) -> Bool {
        let pb = NSPasteboard.general
        if let fileURL = clipboardImageFileURL(), let img = NSImage(contentsOf: fileURL) {
            acceptSelectedPhoto(img, label: fileURL.lastPathComponent)
            return true
        }
        if let pngData = pb.data(forType: .png), let img = NSImage(data: pngData) {
            acceptSelectedPhoto(img, label: L10n.t("剪贴板图片", "Clipboard Image"))
            return true
        }
        if let tiffData = pb.data(forType: .tiff), let img = NSImage(data: tiffData) {
            acceptSelectedPhoto(img, label: L10n.t("剪贴板图片", "Clipboard Image"))
            return true
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let first = imgs.first {
            acceptSelectedPhoto(first, label: L10n.t("剪贴板图片", "Clipboard Image"))
            return true
        }
        if showEmptyHint {
            photoStatusIsError = false
            photoStatusIsWarning = true
            photoStatusMessage = L10n.t("剪贴板中当前没有图片，请先截图或复制照片后再按 ⌘V", "No image in clipboard. Copy a photo or screenshot first, then press ⌘V.")
        }
        return false
    }

    private func handlePhotoDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let resolvedURL: URL?
                    if let data = item as? Data {
                        resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let url = item as? URL {
                        resolvedURL = url
                    } else {
                        resolvedURL = nil
                    }
                    guard let fileURL = resolvedURL, let img = NSImage(contentsOf: fileURL) else { return }
                    DispatchQueue.main.async {
                        self.acceptSelectedPhoto(img, label: fileURL.lastPathComponent)
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data = data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self.acceptSelectedPhoto(img, label: L10n.t("拖入图片", "Dropped Image"))
                    }
                }
                return true
            }
        }
        return false
    }

    private func acceptSelectedPhoto(_ image: NSImage, label: String) {
        guard let compressedDataURL = SOTDPhotoCompressor.compressToJPEGDataURL(image: image, maxLongEdge: 1280, quality: 0.82) else {
            photoStatusIsError = true
            photoStatusIsWarning = false
            photoStatusMessage = L10n.t("图片压缩失败，请尝试其他照片格式", "Failed to compress image. Please try another photo.")
            return
        }
        selectedPhotoImage = image
        selectedPhotoDataURL = compressedDataURL
        selectedPhotoLabel = label
        photoStatusMessage = nil
        photoStatusIsError = false
        photoStatusIsWarning = false

        // 若 AI 接口已配置就绪则自动触发识别，否则保留按钮供配置后点击
        if store.aiConfig.isReady {
            Task { await runPhotoRecognition() }
        } else {
            photoStatusIsWarning = true
            photoStatusMessage = L10n.t(
                "照片已就绪，请先在「外观与设置 → AI 识别接口」启用并配置支持视觉的模型后点击「AI 识别装备」",
                "Photo ready. Enable and configure a vision-capable AI model in Settings, then click Identify Gear."
            )
        }
    }

    private func clearSelectedPhoto() {
        selectedPhotoImage = nil
        selectedPhotoDataURL = nil
        selectedPhotoLabel = ""
        photoStatusMessage = nil
        photoStatusIsError = false
        photoStatusIsWarning = false
    }

    private func inHandCatalogNamesByCategory() -> [GearCategory: [String]] {
        var result: [GearCategory: [String]] = [:]
        for cat in GearCategory.allCases {
            let items = store.gearItems(for: cat)
            let preferred = items.filter { $0.status.isDefaultNormal || $0.status == .borrowed }
            let others = items.filter { !$0.status.isDefaultNormal && $0.status != .borrowed }
            let ordered = (preferred + others).map(\.name)
            result[cat] = Array(ordered.prefix(60))
        }
        return result
    }

    private func runPhotoRecognition() async {
        guard let dataURL = selectedPhotoDataURL, !isRecognizingPhoto else { return }

        guard store.aiConfig.isReady else {
            photoStatusIsError = true
            photoStatusIsWarning = false
            photoStatusMessage = L10n.t(
                "请先在「外观与设置 → AI 识别接口」中启用并填写 API Key",
                "Please enable and configure your AI API key in Settings first."
            )
            return
        }

        isRecognizingPhoto = true
        photoStatusMessage = nil
        photoStatusIsError = false
        photoStatusIsWarning = false
        defer { isRecognizingPhoto = false }

        do {
            let parsed = try await WebGearRecognizer.shared.recognizeSOTDPhoto(
                imageDataURL: dataURL,
                catalog: inHandCatalogNamesByCategory(),
                aiConfig: store.aiConfig
            )

            var bladeSuggestedCount: Int? = nil
            if let v = parsed.razor { razor = v }
            if let v = parsed.blade {
                bladeBase = v
                let suggested = store.suggestedNextUseCount(forBlade: v)
                bladeUseCount = suggested
                bladeSuggestedCount = suggested
            }
            if let v = parsed.brush { brush = v }
            if let v = parsed.soap { soap = v }
            if let v = parsed.bowl {
                bowlName = v
                latheringMode = .bowl
            }
            if let v = parsed.preShave { preShave = v }
            if let v = parsed.afterShave { afterShave = v }

            let count = parsed.recognizedFieldCount
            if count == 0 {
                photoStatusIsWarning = true
                if let note = parsed.uncertainNote, !note.isEmpty {
                    photoStatusMessage = L10n.t(
                        "未从照片中识别到明确装备（\(note)）",
                        "No gear clearly identified (\(note))"
                    )
                } else {
                    photoStatusMessage = L10n.t(
                        "照片中未识别到明确的湿剃装备，请尝试更清晰的照片或手动填写",
                        "No shaving gear clearly identified in the photo. Try a clearer image or fill manually."
                    )
                }
            } else {
                var summaryZH = "已识别并预填 \(count) 项装备"
                var summaryEN = "Identified & prefilled \(count) \(count == 1 ? "item" : "items")"
                if let cnt = bladeSuggestedCount {
                    summaryZH += "（刀片已自动建议第 \(cnt) 次）"
                    summaryEN += " (blade set to \(L10n.ordinal(cnt)))"
                }
                if let note = parsed.uncertainNote, !note.isEmpty {
                    summaryZH += " · 核对提示：\(note)"
                    summaryEN += " · Check: \(note)"
                    photoStatusIsWarning = true
                }
                photoStatusMessage = L10n.t(summaryZH, summaryEN)
            }
        } catch let clientErr as AIClientError {
            photoStatusIsError = true
            if case .visionNotSupported = clientErr {
                photoStatusMessage = clientErr.localizedDescription
            } else {
                photoStatusMessage = L10n.t(
                    "图片识别失败：\(clientErr.localizedDescription)",
                    "Image recognition failed: \(clientErr.localizedDescription)"
                )
            }
        } catch {
            photoStatusIsError = true
            photoStatusMessage = L10n.t(
                "图片识别失败：\(error.localizedDescription)",
                "Image recognition failed: \(error.localizedDescription)"
            )
        }
    }

    private func runNaturalLanguageParse() async {
        let sentence = naturalInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }

        guard store.aiConfig.isReady else {
            naturalStatusIsError = true
            naturalStatusMessage = L10n.t("请先在「外观与设置 → AI 识别接口」中启用并填写 API Key", "Please enable and configure your AI API key in Settings first.")
            return
        }

        isParsingNatural = true
        naturalStatusMessage = nil
        defer { isParsingNatural = false }

        do {
            let parsed = try await WebGearRecognizer.shared.parseNaturalLanguageSOTD(
                sentence: sentence,
                catalog: store.catalogNamesByCategory(),
                aiConfig: store.aiConfig
            )
            if let v = parsed.razor { razor = v }
            if let v = parsed.blade {
                bladeBase = v
                if let cnt = parsed.bladeUseCount {
                    bladeUseCount = max(1, min(50, cnt))
                } else {
                    bladeUseCount = store.suggestedNextUseCount(forBlade: v)
                }
            } else if let cnt = parsed.bladeUseCount {
                bladeUseCount = max(1, min(50, cnt))
            }
            if let v = parsed.brush { brush = v }
            if let v = parsed.soap { soap = v }
            if let v = parsed.bowl { bowlName = v }
            if let v = parsed.preShave { preShave = v }
            if let v = parsed.afterShave { afterShave = v }
            if let m = parsed.loadingMethod { loadingMethod = m }
            if let l = parsed.latheringMethod { latheringMode = l }
            if let h = parsed.hotTowel { hotTowel = h }
            if let a = parsed.afterShower { afterShower = a }
            if let al = parsed.useAlum { useAlum = al }
            if !parsed.passes.isEmpty {
                var newMap: [ShavePassType: String] = [:]
                for step in parsed.passes { newMap[step.pass] = step.setting }
                selectedPasses = newMap
            }
            if let r = parsed.result { shaveResult = r }
            if let i = parsed.irritation { irritation = i }
            if let n = parsed.note { processNote = n }

            naturalStatusIsError = false
            naturalStatusMessage = L10n.t("AI 已解析并填入表单，请核对后保存", "Parsed and filled form — please review before saving.")
        } catch {
            naturalStatusIsError = true
            naturalStatusMessage = L10n.t("AI 解析失败：\(error.localizedDescription)", "AI parse failed: \(error.localizedDescription)")
        }
    }

    private func loadInitialValues() {
        if let e = editingEntry {
            date = e.parsedDate ?? Date()
            razor = e.primaryRazor
            let bladeParsed = GearKnowledgeBase.parseBladeUsage(e.primaryBlade)
            bladeBase = bladeParsed.baseName
            bladeUseCount = bladeParsed.useCount ?? 1
            brush = e.brush
            soap = e.soap
            bowlName = e.bowl
            preShave = e.preShave == "无" ? "" : e.preShave
            afterShave = e.afterShave == "无" ? "" : e.afterShave

            if let lm = LatheringMethod(rawValue: e.pureLatheringMethod) {
                latheringMode = lm
            } else {
                latheringMode = bowlName.isEmpty ? .face : .bowl
            }

            if let m = SoapLoadingMethod(rawValue: e.loadingMethod) {
                loadingMethod = m
            } else if e.loadingMethod == "涂取" {
                loadingMethod = .apply
            }

            afterShower = e.afterShower.hasPrefix("是")
            hotTowel = e.hotTowel
            useAlum = e.alum.hasPrefix("是")

            let parsed = JournalStore.parseProcess(e.processText)
            selectedPasses = [:]
            for step in parsed.passes {
                selectedPasses[step.pass] = step.setting
            }
            if let res = parsed.result { shaveResult = res }
            if let irr = parsed.irritation { irritation = irr }
            processNote = parsed.note
            return
        }

        if let prefilledDate = initialDate {
            date = prefilledDate
        }

        if let d = draft {
            razor = d.razor
            bladeBase = d.blade
            if !d.blade.isEmpty {
                bladeUseCount = store.suggestedNextUseCount(forBlade: d.blade)
            }
            brush = d.brush
            soap = d.soap
            bowlName = d.bowl
            preShave = d.preShave
            afterShave = d.afterShave
            latheringMode = d.bowl.isEmpty ? .face : .bowl
            return
        }

        if let latest = store.database.entries.first {
            preShave = latest.preShave == "无" ? "" : latest.preShave
            afterShave = latest.afterShave == "无" ? "" : latest.afterShave
            bowlName = latest.bowl
            if let lm = LatheringMethod(rawValue: latest.pureLatheringMethod) {
                latheringMode = lm
            }
        }
    }

    private func buildProcessString() -> String {
        let orderedPasses = ShavePassType.allCases.compactMap { p -> PassStep? in
            guard let setting = selectedPasses[p] else { return nil }
            return PassStep(pass: p, setting: setting)
        }
        let parsed = ParsedProcess(passes: orderedPasses, result: shaveResult, irritation: irritation, note: processNote)
        return parsed.formattedString(isAdjustable: isAdjustableRazor)
    }

    private func saveEntry() {
        saveErrorMessage = nil
        let dateStr = JournalDateFormatter.isoDay.string(from: date)
        let bladeValue: String = {
            let trimmed = bladeBase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            return "\(trimmed) \(L10n.ordinal(bladeUseCount))"
        }()

        let cleanBowl = bowlName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPre = preShave.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAfter = afterShave.trimmingCharacters(in: .whitespacesAndNewlines)

        let fields = JournalEntry.buildMergedFields(
            existingEntry: editingEntry,
            dateStr: dateStr,
            razor: razor.trimmingCharacters(in: .whitespacesAndNewlines),
            blade: bladeValue,
            brush: brush.trimmingCharacters(in: .whitespacesAndNewlines),
            soap: soap.trimmingCharacters(in: .whitespacesAndNewlines),
            bowl: cleanBowl,
            preShave: cleanPre,
            afterShave: cleanAfter,
            afterShower: afterShower,
            hotTowel: hotTowel,
            useAlum: useAlum,
            processText: buildProcessString(),
            loadingMethod: loadingMethod.rawValue,
            latheringMethod: latheringMode.rawValue
        )

        let entry = JournalEntry(
            id: editingEntry?.id ?? "local-\(UUID().uuidString)",
            date: dateStr,
            fields: fields,
            sourceFingerprint: editingEntry?.sourceFingerprint,
            locallyModified: true
        )
        let currentFieldValues: [GearCategory: String] = [
            .razor: razor.trimmingCharacters(in: .whitespacesAndNewlines),
            .blade: bladeBase.trimmingCharacters(in: .whitespacesAndNewlines),
            .brush: brush.trimmingCharacters(in: .whitespacesAndNewlines),
            .soap: soap.trimmingCharacters(in: .whitespacesAndNewlines),
            .bowl: cleanBowl,
            .preShave: cleanPre,
            .afterShave: cleanAfter
        ]
        let activeBindings: [(category: GearCategory, insertedText: String, item: GearItem)] = selectedGearBindings.compactMap { cat, pair in
            guard let current = currentFieldValues[cat], current == pair.text else { return nil }
            return (cat, pair.text, pair.item)
        }

        switch store.upsertEntry(entry, selectedGearBindings: activeBindings) {
        case .success:
            store.showToast(L10n.t("已保存 SOTD 日记", "Saved SOTD entry"), isLoading: false)
            onSaved?(entry)
            dismiss()
        case .failure(let error):
            saveErrorMessage = error.localizedDescription
        }
    }
}

struct GearAutocompleteField: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    let title: String
    let category: GearCategory
    @Binding var text: String
    var placeholder: String
    var onSelectItem: ((GearItem, String) -> Void)? = nil

    @State private var isExpanded: Bool = false
    @State private var isHoveringDropdown: Bool = false
    @State private var showQuickCreateAlert: Bool = false
    @State private var newItemName: String = ""
    @State private var newItemBrand: String = ""
    @State private var quickCreateError: String? = nil
    @FocusState private var isFocused: Bool

    private var candidates: [GearItem] {
        Array(store.searchCandidates(for: category, query: text).prefix(8))
    }

    private var allItems: [GearItem] {
        store.searchCandidates(for: category, query: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 7) {
                HStack(spacing: 6) {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .focused($isFocused)
                        .onChange(of: text) { _, _ in
                            if isFocused { isExpanded = true }
                        }
                        .onChange(of: isFocused) { _, focused in
                            if focused {
                                isExpanded = true
                            } else if !isHoveringDropdown {
                                isExpanded = false
                            }
                        }
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8.5)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(ShaveTheme.subtleSurface(scheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(isFocused ? ShaveTheme.accent : ShaveTheme.cardBorder(scheme), lineWidth: isFocused ? 1.4 : 1)
                )

                Menu {
                    ForEach(allItems.prefix(40)) { item in
                        Button {
                            let inserted = GearCatalogService.autocompleteInsertText(for: item, in: allItems)
                            text = inserted
                            isExpanded = false
                            isFocused = false
                            onSelectItem?(item, inserted)
                        } label: {
                            Text("[\(L10n.brandDisplay(item.brand))] \(item.model) (\(item.count))")
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help(L10n.t("从器材库下拉选择", "Select from Gear Library"))

                Button {
                    newItemName = text
                    newItemBrand = ""
                    showQuickCreateAlert = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(ShaveTheme.accent)
                .help(L10n.t("新建\(title)", "Add New \(title)"))
            }

            if isExpanded && !candidates.isEmpty && (isFocused || isHoveringDropdown) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { item in
                        Button {
                            let inserted = GearCatalogService.autocompleteInsertText(for: item, in: allItems)
                            text = inserted
                            isHoveringDropdown = false
                            isExpanded = false
                            isFocused = false
                            onSelectItem?(item, inserted)
                        } label: {
                            HStack(spacing: 8) {
                                BrandAvatarView(brand: item.brand, size: 22, maxWidth: 30, category: category)
                                Text(L10n.brandDisplay(item.brand))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(item.model)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let gap = GearSpecFormatter.shortSpecTag(item.gapOrSpec) {
                                    TagPill(text: gap, neutral: true)
                                }
                                if let ks = item.knotSize, !ks.isEmpty {
                                    TagPill(text: ks, color: ShaveTheme.accent)
                                }
                                if let hb = item.handleBrand, !hb.isEmpty {
                                    TagPill(text: L10n.handleTag(hb), neutral: true)
                                }
                                if item.isSample {
                                    TagPill(text: L10n.t("小样", "Sample"), color: ShaveTheme.slate)
                                }
                                if !item.status.isDefaultNormal {
                                    TagPill(text: item.status.displayName, color: ShaveTheme.statusColor(for: item.status))
                                }
                                Spacer()
                                Text("\(item.count)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if item.id != candidates.last?.id {
                            Divider().padding(.leading, 11)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ShaveTheme.cardBackground(scheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
                .onHover { hovering in
                    isHoveringDropdown = hovering
                    if !hovering && !isFocused {
                        isExpanded = false
                    }
                }
            }
        }
        .sheet(isPresented: $showQuickCreateAlert) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.t("新建\(title)", "Add \(title)"))
                    .font(.headline)
                TextField(L10n.t("名称", "Name"), text: $newItemName)
                    .textFieldStyle(.roundedBorder)
                TextField(L10n.t("品牌（选填）", "Brand (Optional)"), text: $newItemBrand)
                    .textFieldStyle(.roundedBorder)
                if let err = quickCreateError {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(ShaveTheme.crimson)
                }
                HStack {
                    Spacer()
                    Button(L10n.t("取消", "Cancel")) {
                        quickCreateError = nil
                        showQuickCreateAlert = false
                    }
                    Button(L10n.t("添加", "Add")) {
                        quickCreateError = nil
                        let trimmed = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        switch store.createQuickGear(category: category, name: trimmed, brand: newItemBrand) {
                        case .success(let ov):
                            text = ov.name
                            showQuickCreateAlert = false
                        case .failure(let error):
                            quickCreateError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaveTheme.accent)
                    .disabled(store.isReadOnlyProtected)
                }
            }
            .padding(22)
            .frame(width: 380)
        }
    }
}
