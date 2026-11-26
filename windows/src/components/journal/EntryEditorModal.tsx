import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  AlertTriangle,
  Camera,
  CheckCircle2,
  Circle,
  Clipboard,
  ImagePlus,
  Info,
  Loader2,
  Minus,
  Plus,
  RotateCcw,
  Sparkles,
  X,
} from "lucide-react";
import {
  compressImageBlobToJpegDataUrl,
  isAIConfigReady,
  parseNaturalLanguageSOTD,
  recognizeSOTDPhoto,
} from "../../lib/aiService";
import { parseBladeUsage } from "../../lib/gearKnowledge";
import {
  categorySingularName,
  irritationDisplay,
  latheringShortDisplay,
  loadingMethodDisplay,
  ordinal,
  passDisplay,
  t,
} from "../../lib/l10n";
import {
  buildMergedFields,
  formatDateISO,
  formatParsedProcess,
  getAfterShave,
  getAfterShower,
  getAlum,
  getBowl,
  getBrush,
  getHotTowel,
  getLoadingMethod,
  getPreShave,
  getPrimaryBlade,
  getPrimaryRazor,
  getProcessText,
  getPureLatheringMethod,
  getSoap,
  parseProcessText,
} from "../../lib/processParser";
import { useJournal } from "../../store/JournalContext";
import {
  ALL_GEAR_CATEGORIES,
  ALL_IRRITATION_LEVELS,
  ALL_LATHERING_METHODS,
  ALL_LOADING_METHODS,
  ALL_SHAVE_PASS_TYPES,
  ALL_SHAVE_RESULTS,
  type GearCategory,
  type IrritationLevel,
  type JournalEntry,
  type LatheringMethod,
  type PassStep,
  type ShavePassType,
  type ShaveResult,
  type SoapLoadingMethod,
  type SOTDDraft,
} from "../../types/journal";
import { SectionCard } from "../ui/SectionCard";
import { TagPill } from "../ui/TagPill";
import { GearAutocompleteField } from "./GearAutocompleteField";

interface EntryEditorModalProps {
  open: boolean;
  editingEntry: JournalEntry | null;
  initialDateISO?: string | null;
  initialDraft?: SOTDDraft | null;
  onClose: () => void;
  onSaved?: (entry: JournalEntry) => void;
}

const DEFAULT_PASSES: Partial<Record<ShavePassType, string>> = {
  顺刮: "",
  逆刮: "",
  补刀: "",
};

function isValidLoading(raw: string): raw is SoapLoadingMethod {
  return raw === "挖取" || raw === "刷取" || raw === "涂抹";
}

function isValidLathering(raw: string): raw is LatheringMethod {
  return raw === "碗起" || raw === "脸起" || raw === "手起";
}

export const EntryEditorModal: React.FC<EntryEditorModalProps> = ({
  open,
  editingEntry,
  initialDateISO = null,
  initialDraft = null,
  onClose,
  onSaved,
}) => {
  const {
    database,
    catalogSnapshot,
    aiConfig,
    isEnglish,
    isReadOnlyProtected,
    checkRazorAdjustable,
    getSuggestedNextBladeUse,
    upsertEntry,
    showToast,
  } = useJournal();

  // AI 一句话自然语言快速填表
  const [naturalInput, setNaturalInput] = useState("");
  const [isParsingNatural, setIsParsingNatural] = useState(false);
  const [naturalStatus, setNaturalStatus] = useState<{
    message: string;
    isError: boolean;
  } | null>(null);

  // AI 拍照 / 传图识别 SOTD 装备
  const [photoDataUrl, setPhotoDataUrl] = useState<string | null>(null);
  const [photoLabel, setPhotoLabel] = useState("");
  const [isPhotoDragOver, setIsPhotoDragOver] = useState(false);
  const [isRecognizingPhoto, setIsRecognizingPhoto] = useState(false);
  const [photoStatus, setPhotoStatus] = useState<{
    message: string;
    tone: "success" | "warning" | "error";
  } | null>(null);
  const photoInputRef = useRef<HTMLInputElement | null>(null);
  const isRecognizingPhotoRef = useRef<boolean>(false);

  const [dateStr, setDateStr] = useState<string>(() => formatDateISO(new Date()));
  const [razor, setRazor] = useState("");
  const [bladeBase, setBladeBase] = useState("");
  const [bladeUseCount, setBladeUseCount] = useState<number>(1);
  const [brush, setBrush] = useState("");
  const [soap, setSoap] = useState("");
  const [bowlName, setBowlName] = useState("");
  const [preShave, setPreShave] = useState("");
  const [afterShave, setAfterShave] = useState("");

  const [loadingMethod, setLoadingMethod] = useState<SoapLoadingMethod>("刷取");
  const [latheringMode, setLatheringMode] = useState<LatheringMethod>("碗起");
  const [afterShower, setAfterShower] = useState(true);
  const [hotTowel, setHotTowel] = useState(false);
  const [useAlum, setUseAlum] = useState(true);

  const [selectedPasses, setSelectedPasses] =
    useState<Partial<Record<ShavePassType, string>>>(DEFAULT_PASSES);
  const [shaveResult, setShaveResult] = useState<ShaveResult>("BBS");
  const [irritation, setIrritation] = useState<IrritationLevel>("无痛");
  const [processNote, setProcessNote] = useState("");
  const [saveError, setSaveError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  // 打开弹窗时初始化表单（与 Mac 版 EntryEditorSheet.loadInitialValues 一致）
  useEffect(() => {
    if (!open) return;
    setSaveError(null);
    setNaturalInput("");
    setNaturalStatus(null);
    setPhotoDataUrl(null);
    setPhotoLabel("");
    setIsPhotoDragOver(false);
    setPhotoStatus(null);

    if (editingEntry) {
      setDateStr(editingEntry.date || formatDateISO(new Date()));
      setRazor(getPrimaryRazor(editingEntry));
      const bladeParsed = parseBladeUsage(getPrimaryBlade(editingEntry));
      setBladeBase(bladeParsed.baseName);
      setBladeUseCount(bladeParsed.useCount ?? 1);
      setBrush(getBrush(editingEntry));
      setSoap(getSoap(editingEntry));
      const bowl = getBowl(editingEntry);
      setBowlName(bowl);
      const pre = getPreShave(editingEntry);
      setPreShave(pre === "无" ? "" : pre);
      const after = getAfterShave(editingEntry);
      setAfterShave(after === "无" ? "" : after);

      const pureLath = getPureLatheringMethod(editingEntry);
      if (isValidLathering(pureLath)) {
        setLatheringMode(pureLath);
      } else {
        setLatheringMode(bowl ? "碗起" : "脸起");
      }

      const load = getLoadingMethod(editingEntry);
      if (isValidLoading(load)) {
        setLoadingMethod(load);
      } else if (load === "涂取") {
        setLoadingMethod("涂抹");
      } else {
        setLoadingMethod("刷取");
      }

      setAfterShower(getAfterShower(editingEntry).startsWith("是"));
      setHotTowel(getHotTowel(editingEntry));
      setUseAlum(getAlum(editingEntry).startsWith("是"));

      const parsed = parseProcessText(getProcessText(editingEntry));
      const nextPasses: Partial<Record<ShavePassType, string>> = {};
      for (const step of parsed.passes) {
        nextPasses[step.pass] = step.setting;
      }
      setSelectedPasses(nextPasses);
      setShaveResult(parsed.result ?? "BBS");
      setIrritation(parsed.irritation ?? "无痛");
      setProcessNote(parsed.note);
      return;
    }

    // 新建日记 / 补记某一天 / 随机抽签带入
    setDateStr(initialDateISO || formatDateISO(new Date()));
    setLoadingMethod("刷取");
    setAfterShower(true);
    setHotTowel(false);
    setUseAlum(true);
    setSelectedPasses({ ...DEFAULT_PASSES });
    setShaveResult("BBS");
    setIrritation("无痛");
    setProcessNote("");

    if (initialDraft) {
      setRazor(initialDraft.razor);
      setBladeBase(initialDraft.blade);
      setBladeUseCount(
        initialDraft.blade
          ? getSuggestedNextBladeUse(initialDraft.blade)
          : 1
      );
      setBrush(initialDraft.brush);
      setSoap(initialDraft.soap);
      setBowlName(initialDraft.bowl);
      setPreShave(initialDraft.preShave);
      setAfterShave(initialDraft.afterShave);
      setLatheringMode(initialDraft.bowl ? "碗起" : "脸起");
      return;
    }

    setRazor("");
    setBladeBase("");
    setBladeUseCount(1);
    setBrush("");
    setSoap("");

    const latest = database.entries[0];
    if (latest) {
      const latestPre = getPreShave(latest);
      const latestAfter = getAfterShave(latest);
      const latestBowl = getBowl(latest);
      const latestLath = getPureLatheringMethod(latest);
      setPreShave(latestPre === "无" ? "" : latestPre);
      setAfterShave(latestAfter === "无" ? "" : latestAfter);
      setBowlName(latestBowl);
      setLatheringMode(isValidLathering(latestLath) ? latestLath : "碗起");
    } else {
      setPreShave("");
      setAfterShave("");
      setBowlName("");
      setLatheringMode("碗起");
    }
  }, [
    open,
    editingEntry,
    initialDateISO,
    initialDraft,
    database.entries,
    getSuggestedNextBladeUse,
  ]);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [open, onClose]);

  const isAdjustable = useMemo(
    () => checkRazorAdjustable(razor),
    [checkRazorAdjustable, razor]
  );

  const buildInHandCatalogNames = useCallback((): Record<
    GearCategory,
    string[]
  > => {
    const result = {} as Record<GearCategory, string[]>;
    for (const cat of ALL_GEAR_CATEGORIES) {
      const items = catalogSnapshot.itemsByCategory[cat] ?? [];
      const preferred = items.filter(
        (item) =>
          item.status === "在用" ||
          item.status === "有" ||
          item.status === "借用"
      );
      const others = items.filter(
        (item) =>
          item.status !== "在用" &&
          item.status !== "有" &&
          item.status !== "借用"
      );
      result[cat] = [...preferred, ...others]
        .slice(0, 60)
        .map((item) => item.name);
    }
    return result;
  }, [catalogSnapshot]);

  const runPhotoRecognition = useCallback(
    async (explicitDataUrl?: string) => {
      const targetDataUrl = explicitDataUrl ?? photoDataUrl;
      if (!targetDataUrl || isRecognizingPhotoRef.current) return;

      if (!isAIConfigReady(aiConfig)) {
        setPhotoStatus({
          message: t(
            "请先在「外观与设置 → AI 识别接口」中启用并保存 API Key",
            "Enable and save your AI API key in Settings first",
            isEnglish
          ),
          tone: "error",
        });
        return;
      }

      isRecognizingPhotoRef.current = true;
      setIsRecognizingPhoto(true);
      setPhotoStatus(null);

      try {
        const parsed = await recognizeSOTDPhoto(
          targetDataUrl,
          buildInHandCatalogNames(),
          aiConfig,
          isEnglish
        );

        let bladeSuggestedCount: number | null = null;
        if (parsed.razor) setRazor(parsed.razor);
        if (parsed.blade) {
          setBladeBase(parsed.blade);
          const suggested = getSuggestedNextBladeUse(parsed.blade);
          setBladeUseCount(suggested);
          bladeSuggestedCount = suggested;
        }
        if (parsed.brush) setBrush(parsed.brush);
        if (parsed.soap) setSoap(parsed.soap);
        if (parsed.bowl) {
          setBowlName(parsed.bowl);
          setLatheringMode("碗起");
        }
        if (parsed.preShave) setPreShave(parsed.preShave);
        if (parsed.afterShave) setAfterShave(parsed.afterShave);

        const count = [
          parsed.razor,
          parsed.blade,
          parsed.brush,
          parsed.soap,
          parsed.bowl,
          parsed.preShave,
          parsed.afterShave,
        ].filter(Boolean).length;

        if (count === 0) {
          setPhotoStatus({
            message: parsed.uncertainNote
              ? t(
                  `未从照片中识别到明确装备（${parsed.uncertainNote}）`,
                  `No gear clearly identified (${parsed.uncertainNote})`,
                  isEnglish
                )
              : t(
                  "照片中未识别到明确的湿剃装备，请尝试更清晰的照片或手动填写",
                  "No shaving gear clearly identified in the photo. Try a clearer image or fill manually.",
                  isEnglish
                ),
            tone: "warning",
          });
        } else {
          let summaryZH = `已识别并预填 ${count} 项装备`;
          let summaryEN = `Identified & prefilled ${count} ${count === 1 ? "item" : "items"}`;
          if (bladeSuggestedCount !== null) {
            summaryZH += `（刀片已自动建议第 ${bladeSuggestedCount} 次）`;
            summaryEN += ` (blade set to ${ordinal(bladeSuggestedCount)})`;
          }
          if (parsed.uncertainNote) {
            summaryZH += ` · 核对提示：${parsed.uncertainNote}`;
            summaryEN += ` · Check: ${parsed.uncertainNote}`;
          }
          setPhotoStatus({
            message: t(summaryZH, summaryEN, isEnglish),
            tone: parsed.uncertainNote ? "warning" : "success",
          });
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        const alreadyFriendly =
          msg.includes("不支持图片识别") ||
          msg.includes("does not support image recognition");
        setPhotoStatus({
          message: alreadyFriendly
            ? msg
            : t(`图片识别失败：${msg}`, `Image recognition failed: ${msg}`, isEnglish),
          tone: "error",
        });
      } finally {
        isRecognizingPhotoRef.current = false;
        setIsRecognizingPhoto(false);
      }
    },
    [
      aiConfig,
      buildInHandCatalogNames,
      getSuggestedNextBladeUse,
      isEnglish,
      photoDataUrl,
    ]
  );

  const acceptPhotoBlob = useCallback(
    async (blob: Blob, label: string) => {
      try {
        const compressed = await compressImageBlobToJpegDataUrl(
          blob,
          1280,
          0.82
        );
        setPhotoDataUrl(compressed);
        setPhotoLabel(label);
        setPhotoStatus(null);
        if (isAIConfigReady(aiConfig)) {
          void runPhotoRecognition(compressed);
        } else {
          setPhotoStatus({
            message: t(
              "照片已就绪，请先在「外观与设置 → AI 识别接口」启用支持视觉的模型后点击「AI 识别装备」",
              "Photo ready. Enable a vision-capable AI model in Settings, then click Identify Gear.",
              isEnglish
            ),
            tone: "warning",
          });
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        setPhotoStatus({
          message: t(
            `图片压缩失败：${msg}`,
            `Failed to compress image: ${msg}`,
            isEnglish
          ),
          tone: "error",
        });
      }
    },
    [aiConfig, isEnglish, runPhotoRecognition]
  );

  // 全局监听 Ctrl+V 粘贴剪贴板图片（仅在剪贴板含图片时拦截，不影响文本输入框正常粘贴）
  useEffect(() => {
    if (!open) return;
    const onPaste = (e: ClipboardEvent) => {
      const items = e.clipboardData?.items;
      if (!items) return;
      for (let i = 0; i < items.length; i += 1) {
        const item = items[i];
        if (item.type.startsWith("image/")) {
          const file = item.getAsFile();
          if (file) {
            e.preventDefault();
            void acceptPhotoBlob(
              file,
              file.name || t("剪贴板图片", "Clipboard Image", isEnglish)
            );
            return;
          }
        }
      }
    };
    window.addEventListener("paste", onPaste);
    return () => window.removeEventListener("paste", onPaste);
  }, [acceptPhotoBlob, isEnglish, open]);

  if (!open) return null;

  const handlePhotoFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    if (!file.type.startsWith("image/")) {
      setPhotoStatus({
        message: t("请选择有效的图片文件", "Please select a valid image file", isEnglish),
        tone: "warning",
      });
      return;
    }
    void acceptPhotoBlob(file, file.name);
  };

  const handlePhotoDrop = (e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.stopPropagation();
    setIsPhotoDragOver(false);
    const files = e.dataTransfer?.files;
    if (!files || files.length === 0) return;
    for (let i = 0; i < files.length; i += 1) {
      const f = files[i];
      if (f.type.startsWith("image/")) {
        void acceptPhotoBlob(f, f.name || t("拖入图片", "Dropped Image", isEnglish));
        return;
      }
    }
    setPhotoStatus({
      message: t("请拖入图片格式文件（JPG / PNG / WebP）", "Please drop an image file (JPG / PNG / WebP)", isEnglish),
      tone: "warning",
    });
  };

  const handlePasteButtonClick = async () => {
    try {
      if (navigator.clipboard && navigator.clipboard.read) {
        const clipItems = await navigator.clipboard.read();
        for (const item of clipItems) {
          const imgType = item.types.find((tp) => tp.startsWith("image/"));
          if (imgType) {
            const blob = await item.getType(imgType);
            await acceptPhotoBlob(
              blob,
              t("剪贴板图片", "Clipboard Image", isEnglish)
            );
            return;
          }
        }
        setPhotoStatus({
          message: t(
            "剪贴板中当前没有图片，请先截图或复制照片后再按 Ctrl+V",
            "No image in clipboard. Copy a photo or screenshot first, then press Ctrl+V.",
            isEnglish
          ),
          tone: "warning",
        });
      } else {
        setPhotoStatus({
          message: t(
            "请直接按 Ctrl+V 粘贴剪贴板中的照片",
            "Press Ctrl+V directly to paste an image from your clipboard",
            isEnglish
          ),
          tone: "warning",
        });
      }
    } catch {
      setPhotoStatus({
        message: t(
          "请直接按 Ctrl+V 粘贴剪贴板中的照片",
          "Press Ctrl+V directly to paste an image from your clipboard",
          isEnglish
        ),
        tone: "warning",
      });
    }
  };

  const handleClearPhoto = () => {
    setPhotoDataUrl(null);
    setPhotoLabel("");
    setPhotoStatus(null);
  };

  const handleNaturalLanguageParse = async () => {
    const sentence = naturalInput.trim();
    if (!sentence || isParsingNatural) return;
    if (!isAIConfigReady(aiConfig)) {
      setNaturalStatus({
        message: t(
          "请先在「外观与设置 → AI 识别接口」中启用并保存 API Key",
          "Enable and save your AI API key in Settings first",
          isEnglish
        ),
        isError: true,
      });
      return;
    }

    setIsParsingNatural(true);
    setNaturalStatus(null);
    try {
      const catalogNames = {} as Record<GearCategory, string[]>;
      for (const cat of ALL_GEAR_CATEGORIES) {
        catalogNames[cat] = (catalogSnapshot.itemsByCategory[cat] ?? []).map(
          (item) => item.name
        );
      }

      const parsed = await parseNaturalLanguageSOTD(
        sentence,
        catalogNames,
        aiConfig,
        isEnglish
      );

      if (parsed.razor) setRazor(parsed.razor);
      if (parsed.blade) {
        setBladeBase(parsed.blade);
        setBladeUseCount(
          parsed.bladeUseCount ?? getSuggestedNextBladeUse(parsed.blade)
        );
      } else if (parsed.bladeUseCount !== null) {
        setBladeUseCount(parsed.bladeUseCount);
      }
      if (parsed.brush) setBrush(parsed.brush);
      if (parsed.soap) setSoap(parsed.soap);
      if (parsed.bowl) setBowlName(parsed.bowl);
      if (parsed.preShave) setPreShave(parsed.preShave);
      if (parsed.afterShave) setAfterShave(parsed.afterShave);
      if (parsed.loadingMethod) setLoadingMethod(parsed.loadingMethod);
      if (parsed.latheringMethod) setLatheringMode(parsed.latheringMethod);
      if (parsed.hotTowel !== null) setHotTowel(parsed.hotTowel);
      if (parsed.afterShower !== null) setAfterShower(parsed.afterShower);
      if (parsed.useAlum !== null) setUseAlum(parsed.useAlum);
      if (parsed.passes.length > 0) {
        const nextPasses: Partial<Record<ShavePassType, string>> = {};
        for (const step of parsed.passes) {
          nextPasses[step.pass] = step.setting;
        }
        setSelectedPasses(nextPasses);
      }
      if (parsed.result) setShaveResult(parsed.result);
      if (parsed.irritation) setIrritation(parsed.irritation);
      if (parsed.note) setProcessNote(parsed.note);

      setNaturalStatus({
        message: t(
          "已自动解析并预填表单，核对无误后点击保存即可",
          "Parsed and pre-filled form. Review and click Save.",
          isEnglish
        ),
        isError: false,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setNaturalStatus({
        message: t(`解析失败：${msg}`, `Parse failed: ${msg}`, isEnglish),
        isError: true,
      });
    } finally {
      setIsParsingNatural(false);
    }
  };

  const togglePass = (pass: ShavePassType) => {
    setSelectedPasses((prev) => {
      const next = { ...prev };
      if (next[pass] !== undefined) {
        delete next[pass];
      } else {
        next[pass] = "";
      }
      return next;
    });
  };

  const updatePassSetting = (pass: ShavePassType, setting: string) => {
    setSelectedPasses((prev) => ({
      ...prev,
      [pass]: setting,
    }));
  };

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!razor.trim() || isReadOnlyProtected || isSaving) return;

    setSaveError(null);
    setIsSaving(true);

    const orderedPasses: PassStep[] = [];
    for (const p of ALL_SHAVE_PASS_TYPES) {
      const setting = selectedPasses[p];
      if (setting !== undefined) {
        orderedPasses.push({ pass: p, setting });
      }
    }

    const processText = formatParsedProcess(
      {
        passes: orderedPasses,
        result: shaveResult,
        irritation,
        note: processNote,
      },
      isAdjustable
    );

    const trimmedBlade = bladeBase.trim();
    const bladeValue = trimmedBlade
      ? `${trimmedBlade} ${ordinal(bladeUseCount)}`
      : "";

    const effectiveDate = dateStr.trim() || formatDateISO(new Date());

    const fields = buildMergedFields({
      existingEntry: editingEntry,
      dateStr: effectiveDate,
      razor: razor.trim(),
      blade: bladeValue,
      brush: brush.trim(),
      soap: soap.trim(),
      bowl: bowlName.trim(),
      preShave: preShave.trim(),
      afterShave: afterShave.trim(),
      afterShower,
      hotTowel,
      useAlum,
      processText,
      loadingMethod,
      latheringMethod: latheringMode,
    });

    const newId =
      editingEntry?.id ??
      `local-${
        typeof crypto !== "undefined" && crypto.randomUUID
          ? crypto.randomUUID().toUpperCase()
          : `${Date.now()}`
      }`;

    const entry: JournalEntry = {
      id: newId,
      date: effectiveDate,
      fields,
      sourceFingerprint: editingEntry?.sourceFingerprint,
      locallyModified: true,
    };

    const res = await upsertEntry(entry);
    setIsSaving(false);
    if (res.ok) {
      showToast(t("已保存 SOTD 日记", "Saved SOTD entry", isEnglish));
      onSaved?.(entry);
      onClose();
    } else {
      setSaveError(res.error ?? t("保存失败", "Failed to save", isEnglish));
    }
  };

  return (
    <div
      className="fixed inset-0 z-40 flex items-center justify-center bg-black/45 p-5 backdrop-blur-[2px]"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <form
        onSubmit={(e) => void handleSave(e)}
        className="flex max-h-[90vh] w-full max-w-[780px] flex-col overflow-hidden rounded-2xl border border-[var(--wsj-border)] bg-[var(--wsj-canvas)] shadow-2xl"
      >
        {/* 顶部栏 */}
        <div className="flex items-center justify-between border-b border-[var(--wsj-border)] bg-[var(--wsj-card)] px-6 py-4">
          <h2 className="text-[19px] font-bold text-[var(--wsj-text)]">
            {editingEntry
              ? t("编辑 SOTD", "Edit SOTD", isEnglish)
              : t("记录今日 SOTD", "New SOTD", isEnglish)}
          </h2>

          <div className="flex items-center gap-3">
            <input
              type="date"
              required
              value={dateStr}
              onChange={(e) => setDateStr(e.target.value)}
              className="rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-subtle)] px-2.5 py-1.5 font-mono text-[13px] font-medium text-[var(--wsj-text)] outline-none focus:border-[var(--wsj-accent)]"
            />
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg p-1.5 text-[var(--wsj-text-secondary)] transition hover:bg-[var(--wsj-subtle)] hover:text-[var(--wsj-text)]"
              aria-label="Close"
            >
              <X className="h-4 w-4" />
            </button>
          </div>
        </div>

        {/* 表单滚动区 */}
        <div className="flex-1 space-y-4 overflow-y-auto p-5">
          {/* AI 功能 ①：一句话自然语言快速记 SOTD */}
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <div className="flex flex-1 items-center gap-2 rounded-[10px] border border-[var(--wsj-accent)]/35 bg-[var(--wsj-card)] px-3 py-2 focus-within:border-[var(--wsj-accent)]">
                <Sparkles className="h-3.5 w-3.5 shrink-0 text-[var(--wsj-accent)]" />
                <input
                  type="text"
                  value={naturalInput}
                  onChange={(e) => setNaturalInput(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") {
                      e.preventDefault();
                      void handleNaturalLanguageParse();
                    }
                  }}
                  placeholder={t(
                    "一句话快速记 SOTD：如「浴后热敷，黑鸟钛配俄纸第2次，Shavemac 26刷，MDC苦艾碗起，顺逆补无痛BBS」",
                    "Quick SOTD: e.g., Post-shower hot towel, Blackbird Ti + Nacet 2nd, Shavemac 26mm, MDC Absinthe bowl lather, WTG/ATG painless BBS",
                    isEnglish
                  )}
                  className="w-full bg-transparent text-[13px] text-[var(--wsj-text)] placeholder:text-[var(--wsj-text-tertiary)] outline-none"
                />
              </div>

              <button
                type="button"
                disabled={isParsingNatural || !naturalInput.trim()}
                onClick={() => void handleNaturalLanguageParse()}
                className="inline-flex shrink-0 items-center gap-1.5 rounded-[10px] bg-[var(--wsj-accent)] px-3.5 py-2 text-[13px] font-semibold text-white transition hover:opacity-90 disabled:opacity-45"
              >
                {isParsingNatural ? (
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                ) : (
                  <Sparkles className="h-3.5 w-3.5" />
                )}
                {isParsingNatural
                  ? t("解析中...", "Parsing...", isEnglish)
                  : t("AI 解析填表", "AI Parse", isEnglish)}
              </button>
            </div>

            {naturalStatus && (
              <div
                className={`pl-1 text-[12px] ${
                  naturalStatus.isError
                    ? "text-[#D1851F]"
                    : "text-[#2E8F5C]"
                }`}
              >
                {naturalStatus.message}
              </div>
            )}
          </div>

          {/* AI 功能 ①-B：📷 拍照 / 传图识别 SOTD 装备（支持选图、拖拽、Ctrl+V 粘贴） */}
          <div className="space-y-1.5">
            <input
              ref={photoInputRef}
              type="file"
              accept="image/*"
              onChange={handlePhotoFileChange}
              className="hidden"
            />

            <div
              onDragOver={(e) => {
                e.preventDefault();
                e.stopPropagation();
                if (!isPhotoDragOver) setIsPhotoDragOver(true);
              }}
              onDragLeave={(e) => {
                e.preventDefault();
                e.stopPropagation();
                setIsPhotoDragOver(false);
              }}
              onDrop={handlePhotoDrop}
              className={`flex flex-wrap items-center gap-3 rounded-[11px] px-3.5 py-2.5 transition ${
                isPhotoDragOver
                  ? "border-[1.5px] border-dashed border-[var(--wsj-accent)] bg-[var(--wsj-accent)]/10"
                  : photoDataUrl
                    ? "border border-[var(--wsj-border)] bg-[var(--wsj-card)]"
                    : "border border-dashed border-[var(--wsj-border)] bg-[var(--wsj-card)] hover:border-[var(--wsj-accent)]/50"
              }`}
            >
              {photoDataUrl ? (
                <>
                  <img
                    src={photoDataUrl}
                    alt="SOTD"
                    className="h-14 w-14 shrink-0 rounded-[9px] border border-[var(--wsj-border)] object-cover"
                  />

                  <div className="min-w-0 flex-1 space-y-0.5">
                    <div className="flex items-center gap-2">
                      <span className="text-[13px] font-semibold text-[var(--wsj-text)]">
                        {t("📷 拍照 / 传图识别", "📷 Photo / Image AI Recognition", isEnglish)}
                      </span>
                      {photoLabel && (
                        <span className="truncate text-[11.5px] text-[var(--wsj-text-secondary)]">
                          {photoLabel}
                        </span>
                      )}
                    </div>
                    <p className="text-[11.5px] text-[var(--wsj-text-tertiary)]">
                      {t(
                        "已自动压缩至长边 ≤ 1280px JPEG · 可继续拖入新照片或按 Ctrl+V 替换",
                        "Compressed to ≤ 1280px JPEG · Drop another photo or press Ctrl+V to replace",
                        isEnglish
                      )}
                    </p>
                  </div>

                  <div className="flex shrink-0 items-center gap-2">
                    <button
                      type="button"
                      disabled={isRecognizingPhoto}
                      onClick={() => void runPhotoRecognition()}
                      className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--wsj-accent)] px-3 py-1.5 text-[12.5px] font-semibold text-white transition hover:opacity-90 disabled:opacity-45"
                    >
                      {isRecognizingPhoto ? (
                        <Loader2 className="h-3.5 w-3.5 animate-spin" />
                      ) : (
                        <Sparkles className="h-3.5 w-3.5" />
                      )}
                      {isRecognizingPhoto
                        ? t("识别中...", "Identifying...", isEnglish)
                        : t("AI 识别装备", "Identify Gear", isEnglish)}
                    </button>

                    <button
                      type="button"
                      disabled={isRecognizingPhoto}
                      onClick={handleClearPhoto}
                      className="inline-flex items-center gap-1 rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-card)] px-2.5 py-1.5 text-[12.5px] font-medium text-[var(--wsj-text)] transition hover:bg-[var(--wsj-subtle)] disabled:opacity-45"
                    >
                      <X className="h-3.5 w-3.5" />
                      {t("清除", "Clear", isEnglish)}
                    </button>
                  </div>
                </>
              ) : (
                <>
                  <div
                    role="button"
                    tabIndex={0}
                    onClick={() => photoInputRef.current?.click()}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" || e.key === " ") {
                        e.preventDefault();
                        photoInputRef.current?.click();
                      }
                    }}
                    className="flex min-w-[220px] flex-1 cursor-pointer items-center gap-2.5"
                  >
                    <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[9px] bg-[var(--wsj-accent)]/12 text-[var(--wsj-accent)]">
                      <Camera className="h-[18px] w-[18px]" />
                    </div>
                    <div className="min-w-0">
                      <div className="text-[13px] font-semibold text-[var(--wsj-text)]">
                        {t(
                          "📷 拍照 / 传图识别 SOTD 装备",
                          "📷 Photo / Image AI Gear Recognition",
                          isEnglish
                        )}
                      </div>
                      <div className="text-[11.5px] text-[var(--wsj-text-secondary)]">
                        {t(
                          "点击选图、拖拽照片到此处，或直接按 Ctrl+V 粘贴剪贴板照片（优先匹配器材库）",
                          "Click to pick, drag & drop a photo here, or press Ctrl+V to paste (matches your gear library)",
                          isEnglish
                        )}
                      </div>
                    </div>
                  </div>

                  <div className="flex shrink-0 items-center gap-2">
                    <button
                      type="button"
                      onClick={() => photoInputRef.current?.click()}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-card)] px-2.5 py-1.5 text-[12.5px] font-medium text-[var(--wsj-text)] transition hover:bg-[var(--wsj-subtle)]"
                    >
                      <ImagePlus className="h-3.5 w-3.5 text-[var(--wsj-accent)]" />
                      {t("选择照片", "Choose Photo", isEnglish)}
                    </button>

                    <button
                      type="button"
                      onClick={() => void handlePasteButtonClick()}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-card)] px-2.5 py-1.5 text-[12.5px] font-medium text-[var(--wsj-text)] transition hover:bg-[var(--wsj-subtle)]"
                    >
                      <Clipboard className="h-3.5 w-3.5 text-[var(--wsj-text-secondary)]" />
                      {t("粘贴 (Ctrl+V)", "Paste (Ctrl+V)", isEnglish)}
                    </button>
                  </div>
                </>
              )}
            </div>

            {photoStatus && (
              <div
                className={`flex items-start gap-1.5 pl-1 text-[12px] ${
                  photoStatus.tone === "error"
                    ? "text-[#CC3D3D]"
                    : photoStatus.tone === "warning"
                      ? "text-[#B97214] dark:text-[#E8A94B]"
                      : "text-[#2E8F5C] dark:text-[#57C288]"
                }`}
              >
                {photoStatus.tone === "error" ? (
                  <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
                ) : photoStatus.tone === "warning" ? (
                  <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" />
                ) : (
                  <CheckCircle2 className="mt-0.5 h-3.5 w-3.5 shrink-0" />
                )}
                <span>{photoStatus.message}</span>
              </div>
            )}
          </div>

          {/* 1. 装备搭配 */}
          <SectionCard>
            <div className="space-y-4">
              <h3 className="text-[15.5px] font-semibold text-[var(--wsj-text)]">
                {t("装备搭配", "Setup", isEnglish)}
              </h3>

              <GearAutocompleteField
                title={categorySingularName("剃须刀", isEnglish)}
                category="剃须刀"
                value={razor}
                onChange={setRazor}
                placeholder={t(
                  "搜索或输入剃须刀...",
                  "Search or enter razor...",
                  isEnglish
                )}
              />

              {/* 刀片 + 使用次数累计 & 换新刀片 */}
              <div className="space-y-2.5">
                <GearAutocompleteField
                  title={categorySingularName("刀片", isEnglish)}
                  category="刀片"
                  value={bladeBase}
                  onChange={setBladeBase}
                  placeholder={t(
                    "搜索或输入刀片...",
                    "Search or enter blade...",
                    isEnglish
                  )}
                  onSelectItem={(selected) => {
                    setBladeUseCount(getSuggestedNextBladeUse(selected.name));
                  }}
                />

                <div className="flex flex-wrap items-center gap-3 pl-0.5">
                  <span className="text-[12.5px] text-[var(--wsj-text-secondary)]">
                    {t("使用次数", "Use Count", isEnglish)}
                  </span>

                  <div className="inline-flex items-center gap-1 rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-subtle)] p-0.5">
                    <button
                      type="button"
                      onClick={() =>
                        setBladeUseCount((c) => Math.max(1, c - 1))
                      }
                      className="flex h-6 w-6 items-center justify-center rounded-md text-[var(--wsj-text)] transition hover:bg-[var(--wsj-card)]"
                      aria-label="Decrease"
                    >
                      <Minus className="h-3.5 w-3.5" />
                    </button>
                    <span className="min-w-[96px] px-2 text-center font-mono text-[13px] font-semibold text-[var(--wsj-accent)]">
                      {isEnglish
                        ? ordinal(bladeUseCount)
                        : `第 ${bladeUseCount} 次 (${ordinal(bladeUseCount)})`}
                    </span>
                    <button
                      type="button"
                      onClick={() =>
                        setBladeUseCount((c) => Math.min(50, c + 1))
                      }
                      className="flex h-6 w-6 items-center justify-center rounded-md text-[var(--wsj-text)] transition hover:bg-[var(--wsj-card)]"
                      aria-label="Increase"
                    >
                      <Plus className="h-3.5 w-3.5" />
                    </button>
                  </div>

                  <button
                    type="button"
                    onClick={() => setBladeUseCount(1)}
                    className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-card)] px-2.5 py-1 text-[12.5px] font-medium text-[var(--wsj-text)] transition hover:bg-[var(--wsj-subtle)]"
                  >
                    <RotateCcw className="h-3.5 w-3.5" />
                    {t("换新刀片 (1st)", "Fresh Blade (1st)", isEnglish)}
                  </button>
                </div>
              </div>

              <GearAutocompleteField
                title={categorySingularName("剃须刷", isEnglish)}
                category="剃须刷"
                value={brush}
                onChange={setBrush}
                placeholder={t(
                  "搜索或输入剃须刷...",
                  "Search or enter brush...",
                  isEnglish
                )}
              />

              <div className="grid grid-cols-1 gap-3.5 sm:grid-cols-2">
                <GearAutocompleteField
                  title={categorySingularName("剃须皂", isEnglish)}
                  category="剃须皂"
                  value={soap}
                  onChange={setSoap}
                  placeholder={t(
                    "搜索或输入剃须皂...",
                    "Search or enter soap...",
                    isEnglish
                  )}
                />
                <GearAutocompleteField
                  title={categorySingularName("剃须碗", isEnglish)}
                  category="剃须碗"
                  value={bowlName}
                  onChange={setBowlName}
                  placeholder={t("选填...", "Optional...", isEnglish)}
                />
              </div>

              <div className="grid grid-cols-1 gap-3.5 sm:grid-cols-2">
                <GearAutocompleteField
                  title={categorySingularName("须前", isEnglish)}
                  category="须前"
                  value={preShave}
                  onChange={setPreShave}
                  placeholder={t("选填...", "Optional...", isEnglish)}
                />
                <GearAutocompleteField
                  title={categorySingularName("须后", isEnglish)}
                  category="须后"
                  value={afterShave}
                  onChange={setAfterShave}
                  placeholder={t("选填...", "Optional...", isEnglish)}
                />
              </div>
            </div>
          </SectionCard>

          {/* 2. 剃须流程 */}
          <SectionCard>
            <div className="space-y-4">
              <h3 className="text-[15.5px] font-semibold text-[var(--wsj-text)]">
                {t("剃须流程", "Prep & Lather", isEnglish)}
              </h3>

              <div className="flex flex-wrap gap-6">
                <div>
                  <div className="mb-1.5 text-[12.5px] text-[var(--wsj-text-secondary)]">
                    {t("取皂方式", "Loading", isEnglish)}
                  </div>
                  <div className="inline-flex rounded-[10px] bg-[var(--wsj-subtle)] p-1">
                    {ALL_LOADING_METHODS.map((m) => {
                      const active = loadingMethod === m;
                      return (
                        <button
                          key={m}
                          type="button"
                          onClick={() => setLoadingMethod(m)}
                          className={`rounded-lg px-3.5 py-1.5 text-[13px] font-medium transition ${
                            active
                              ? "bg-[var(--wsj-card)] text-[var(--wsj-text)] shadow-sm"
                              : "text-[var(--wsj-text-secondary)] hover:text-[var(--wsj-text)]"
                          }`}
                        >
                          {loadingMethodDisplay(m, isEnglish)}
                        </button>
                      );
                    })}
                  </div>
                </div>

                <div>
                  <div className="mb-1.5 text-[12.5px] text-[var(--wsj-text-secondary)]">
                    {t("起泡方式", "Lathering", isEnglish)}
                  </div>
                  <div className="inline-flex rounded-[10px] bg-[var(--wsj-subtle)] p-1">
                    {ALL_LATHERING_METHODS.map((m) => {
                      const active = latheringMode === m;
                      return (
                        <button
                          key={m}
                          type="button"
                          onClick={() => setLatheringMode(m)}
                          className={`rounded-lg px-3.5 py-1.5 text-[13px] font-medium transition ${
                            active
                              ? "bg-[var(--wsj-card)] text-[var(--wsj-text)] shadow-sm"
                              : "text-[var(--wsj-text-secondary)] hover:text-[var(--wsj-text)]"
                          }`}
                        >
                          {latheringShortDisplay(m, isEnglish)}
                        </button>
                      );
                    })}
                  </div>
                </div>
              </div>

              {/* 开关项 */}
              <div className="flex flex-wrap items-center gap-6 pt-0.5">
                {[
                  {
                    label: t("热敷", "Hot Towel", isEnglish),
                    checked: hotTowel,
                    onChange: setHotTowel,
                  },
                  {
                    label: t("浴后", "Post-Shower", isEnglish),
                    checked: afterShower,
                    onChange: setAfterShower,
                  },
                  {
                    label: t("明矾", "Alum Block", isEnglish),
                    checked: useAlum,
                    onChange: setUseAlum,
                  },
                ].map((item) => (
                  <label
                    key={item.label}
                    className="inline-flex cursor-pointer items-center gap-2.5 select-none"
                  >
                    <button
                      type="button"
                      role="switch"
                      aria-checked={item.checked}
                      onClick={() => item.onChange(!item.checked)}
                      className={`relative inline-flex h-[22px] w-10 items-center rounded-full transition ${
                        item.checked
                          ? "bg-[var(--wsj-accent)]"
                          : "bg-[var(--wsj-pill)]"
                      }`}
                    >
                      <span
                        className={`inline-block h-[18px] w-[18px] transform rounded-full bg-white shadow transition ${
                          item.checked ? "translate-x-[20px]" : "translate-x-[2px]"
                        }`}
                      />
                    </button>
                    <span className="text-[13.5px] font-medium text-[var(--wsj-text)]">
                      {item.label}
                    </span>
                  </label>
                ))}
              </div>
            </div>
          </SectionCard>

          {/* 3. 过程与体验 */}
          <SectionCard>
            <div className="space-y-4">
              <div className="flex items-center gap-2.5">
                <h3 className="text-[15.5px] font-semibold text-[var(--wsj-text)]">
                  {t("过程与体验", "Passes & Result", isEnglish)}
                </h3>
                {isAdjustable && (
                  <TagPill
                    text={t("可调刀", "Adjustable", isEnglish)}
                    tone="accent"
                  />
                )}
              </div>

              {/* 刮剃步骤：四列顶部对齐（items-start），档位槽位定高防跳动 */}
              <div className="grid grid-cols-4 items-start gap-2.5">
                {ALL_SHAVE_PASS_TYPES.map((pass) => {
                  const isOn = selectedPasses[pass] !== undefined;
                  return (
                    <div key={pass} className="flex flex-col items-stretch">
                      <button
                        type="button"
                        onClick={() => togglePass(pass)}
                        className={`flex h-10 w-full items-center justify-center gap-1.5 rounded-[10px] text-[13.5px] font-semibold transition ${
                          isOn
                            ? "bg-[var(--wsj-accent)] text-white"
                            : "bg-[var(--wsj-subtle)] text-[var(--wsj-text)] hover:opacity-85"
                        }`}
                      >
                        {isOn ? (
                          <CheckCircle2 className="h-3.5 w-3.5 shrink-0" />
                        ) : (
                          <Circle className="h-3.5 w-3.5 shrink-0 opacity-50" />
                        )}
                        <span>{passDisplay(pass, isEnglish)}</span>
                      </button>

                      {isAdjustable && (
                        <div className="mt-1.5 flex h-8 items-center justify-center">
                          {isOn ? (
                            <div className="flex items-center gap-1.5">
                              <span className="text-[12px] text-[var(--wsj-text-secondary)]">
                                {t("档位", "Set", isEnglish)}
                              </span>
                              <input
                                type="text"
                                placeholder="5"
                                value={selectedPasses[pass] ?? ""}
                                onChange={(e) =>
                                  updatePassSetting(pass, e.target.value)
                                }
                                className="h-7 w-14 rounded-md border border-[var(--wsj-border)] bg-[var(--wsj-subtle)] px-2 text-center font-mono text-[13px] text-[var(--wsj-text)] outline-none focus:border-[var(--wsj-accent)]"
                              />
                            </div>
                          ) : (
                            <div className="h-7 w-full" aria-hidden="true" />
                          )}
                        </div>
                      )}
                    </div>
                  );
                })}
              </div>

              {/* 剃须效果 & 刺激程度 */}
              <div className="flex flex-wrap gap-6">
                <div>
                  <div className="mb-1.5 text-[12.5px] text-[var(--wsj-text-secondary)]">
                    {t("剃须效果", "Closeness", isEnglish)}
                  </div>
                  <div className="inline-flex rounded-[10px] bg-[var(--wsj-subtle)] p-1">
                    {ALL_SHAVE_RESULTS.map((res) => {
                      const active = shaveResult === res;
                      return (
                        <button
                          key={res}
                          type="button"
                          onClick={() => setShaveResult(res)}
                          className={`rounded-lg px-3.5 py-1.5 text-[13px] font-medium transition ${
                            active
                              ? "bg-[var(--wsj-card)] text-[var(--wsj-text)] shadow-sm"
                              : "text-[var(--wsj-text-secondary)] hover:text-[var(--wsj-text)]"
                          }`}
                        >
                          {res}
                        </button>
                      );
                    })}
                  </div>
                </div>

                <div>
                  <div className="mb-1.5 text-[12.5px] text-[var(--wsj-text-secondary)]">
                    {t("刺激程度", "Comfort", isEnglish)}
                  </div>
                  <div className="inline-flex rounded-[10px] bg-[var(--wsj-subtle)] p-1">
                    {ALL_IRRITATION_LEVELS.map((lvl) => {
                      const active = irritation === lvl;
                      return (
                        <button
                          key={lvl}
                          type="button"
                          onClick={() => setIrritation(lvl)}
                          className={`rounded-lg px-3.5 py-1.5 text-[13px] font-medium transition ${
                            active
                              ? "bg-[var(--wsj-card)] text-[var(--wsj-text)] shadow-sm"
                              : "text-[var(--wsj-text-secondary)] hover:text-[var(--wsj-text)]"
                          }`}
                        >
                          {irritationDisplay(lvl, isEnglish)}
                        </button>
                      );
                    })}
                  </div>
                </div>
              </div>

              {/* 备注 */}
              <div>
                <label className="mb-1.5 block text-[12.5px] text-[var(--wsj-text-secondary)]">
                  {t("备注（选填）", "Notes (Optional)", isEnglish)}
                </label>
                <input
                  type="text"
                  value={processNote}
                  onChange={(e) => setProcessNote(e.target.value)}
                  placeholder={t(
                    "例如：有血点、泡沫偏干...",
                    "e.g., weeper, dry lather...",
                    isEnglish
                  )}
                  className="w-full rounded-[9px] border border-[var(--wsj-border)] bg-[var(--wsj-subtle)] px-3 py-2 text-[13.5px] text-[var(--wsj-text)] placeholder:text-[var(--wsj-text-tertiary)] outline-none focus:border-[var(--wsj-accent)]"
                />
              </div>
            </div>
          </SectionCard>
        </div>

        {/* 底部操作栏 */}
        <div className="border-t border-[var(--wsj-border)] bg-[var(--wsj-card)] px-6 py-3.5">
          {saveError && (
            <div className="mb-2.5 flex items-center gap-2 text-[12.5px] text-[#CC3D3D]">
              <AlertTriangle className="h-4 w-4 shrink-0" />
              <span className="truncate">{saveError}</span>
            </div>
          )}

          <div className="flex items-center justify-end gap-2.5">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-subtle)] px-4 py-1.5 text-[13.5px] font-medium text-[var(--wsj-text)] transition hover:opacity-85"
            >
              {t("取消", "Cancel", isEnglish)}
            </button>
            <button
              type="submit"
              disabled={!razor.trim() || isReadOnlyProtected || isSaving}
              className="rounded-lg bg-[var(--wsj-accent)] px-4 py-1.5 text-[13.5px] font-semibold text-white transition hover:opacity-90 disabled:opacity-45"
            >
              {editingEntry
                ? t("更新日记", "Update Entry", isEnglish)
                : t("保存日记", "Save Entry", isEnglish)}
            </button>
          </div>
        </div>
      </form>
    </div>
  );
};
