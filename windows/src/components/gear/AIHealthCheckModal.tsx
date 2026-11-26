import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  AlertTriangle,
  ArrowRight,
  CheckCircle2,
  Info,
  Loader2,
  RotateCcw,
  Sparkles,
  Trash2,
  X,
} from "lucide-react";
import { auditGearItems, isAIConfigReady } from "../../lib/aiService";
import { brandDisplay, categoryPluralName, t } from "../../lib/l10n";
import {
  clearAiHealthCheckSession,
  isTauriRuntime,
  loadAiHealthCheckSession,
  saveAiHealthCheckSession,
} from "../../lib/tauriApi";
import { useJournal } from "../../store/JournalContext";
import type {
  AIHealthCheckSession,
  GearAuditBatchFailure,
  GearAuditMergeProposal,
  GearAuditUpdateProposal,
  GearCategory,
  GearItem,
} from "../../types/journal";
import { TagPill } from "../ui/TagPill";

interface AIHealthCheckModalProps {
  open: boolean;
  initialCategory: GearCategory;
  onClose: () => void;
}

type AuditScope = "currentCategory" | "allPending";
const MAX_RETRY_ROUNDS = 3;
const LOCAL_STORAGE_SESSION_KEY = "wsj_ai_health_check_session_v1";

function hasActionableSessionContent(session: AIHealthCheckSession): boolean {
  return (
    session.updates.length > 0 ||
    session.merges.length > 0 ||
    session.failedItems.length > 0 ||
    session.undeterminedItems.length > 0 ||
    session.batchFailures.length > 0
  );
}

async function readPersistedSession(): Promise<AIHealthCheckSession | null> {
  try {
    if (isTauriRuntime()) {
      const loaded = await loadAiHealthCheckSession();
      if (loaded && hasActionableSessionContent(loaded)) {
        return loaded;
      }
      return null;
    }
    const raw = window.localStorage.getItem(LOCAL_STORAGE_SESSION_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as AIHealthCheckSession;
    return parsed && hasActionableSessionContent(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

async function writePersistedSession(
  session: AIHealthCheckSession
): Promise<void> {
  try {
    if (!hasActionableSessionContent(session)) {
      await removePersistedSession();
      return;
    }
    if (isTauriRuntime()) {
      await saveAiHealthCheckSession(session);
    } else {
      window.localStorage.setItem(
        LOCAL_STORAGE_SESSION_KEY,
        JSON.stringify(session)
      );
    }
  } catch {
    // 缓存写入失败不影响主流程
  }
}

async function removePersistedSession(): Promise<void> {
  try {
    if (isTauriRuntime()) {
      await clearAiHealthCheckSession();
    } else {
      window.localStorage.removeItem(LOCAL_STORAGE_SESSION_KEY);
    }
  } catch {
    // ignore
  }
}

export const AIHealthCheckModal: React.FC<AIHealthCheckModalProps> = ({
  open,
  initialCategory,
  onClose,
}) => {
  const {
    catalogSnapshot,
    allPendingGearItems,
    aiConfig,
    isEnglish,
    isReadOnlyProtected,
    applyAuditProposals,
  } = useJournal();

  const [scope, setScope] = useState<AuditScope>("currentCategory");
  const [isAuditing, setIsAuditing] = useState(false);
  const [hasCompleted, setHasCompleted] = useState(false);
  const [resumedFromDisk, setResumedFromDisk] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [infoBanner, setInfoBanner] = useState<string | null>(null);
  const [modelUsed, setModelUsed] = useState<string | null>(null);

  const [updates, setUpdates] = useState<GearAuditUpdateProposal[]>([]);
  const [merges, setMerges] = useState<GearAuditMergeProposal[]>([]);
  const [undeterminedItems, setUndeterminedItems] = useState<GearItem[]>([]);
  const [failedItems, setFailedItems] = useState<GearItem[]>([]);
  const [batchFailures, setBatchFailures] = useState<GearAuditBatchFailure[]>(
    []
  );

  const [plannedCount, setPlannedCount] = useState(0);
  const [verifiedCount, setVerifiedCount] = useState(0);
  const [skippedCount, setSkippedCount] = useState(0);
  const [unknownIdCount, setUnknownIdCount] = useState(0);
  const [liveUndeterminedCount, setLiveUndeterminedCount] = useState(0);
  const [liveFailedCount, setLiveFailedCount] = useState(0);
  const [currentBatch, setCurrentBatch] = useState(0);
  const [totalBatches, setTotalBatches] = useState(0);
  const [retryRound, setRetryRound] = useState(0);
  const [isApplying, setIsApplying] = useState(false);

  const cancelledRef = useRef(false);

  const persistSessionSnapshot = useCallback(
    (snapshot: {
      scope: AuditScope;
      modelUsed: string | null;
      plannedCount: number;
      verifiedCount: number;
      skippedCount: number;
      unknownIdCount: number;
      retryRound: number;
      updates: GearAuditUpdateProposal[];
      merges: GearAuditMergeProposal[];
      undeterminedItems: GearItem[];
      failedItems: GearItem[];
      batchFailures: GearAuditBatchFailure[];
    }) => {
      const payload: AIHealthCheckSession = {
        schemaVersion: 1,
        savedAt: new Date().toISOString(),
        scope: snapshot.scope,
        category: snapshot.scope === "currentCategory" ? initialCategory : null,
        modelUsed: snapshot.modelUsed,
        plannedCount: snapshot.plannedCount,
        verifiedCount: snapshot.verifiedCount,
        skippedCount: snapshot.skippedCount,
        unknownOrDuplicateIdCount: snapshot.unknownIdCount,
        retryRound: snapshot.retryRound,
        updates: snapshot.updates,
        merges: snapshot.merges,
        undeterminedItems: snapshot.undeterminedItems,
        failedItems: snapshot.failedItems,
        batchFailures: snapshot.batchFailures,
      };
      void writePersistedSession(payload);
    },
    [initialCategory]
  );

  useEffect(() => {
    if (!open) {
      cancelledRef.current = true;
      return;
    }
    cancelledRef.current = false;
    setErrorMessage(null);
    setInfoBanner(null);

    let active = true;
    void readPersistedSession().then((saved) => {
      if (!active || !saved) return;
      setScope(saved.scope === "allPending" ? "allPending" : "currentCategory");
      setModelUsed(saved.modelUsed ?? null);
      setPlannedCount(saved.plannedCount ?? 0);
      setVerifiedCount(saved.verifiedCount ?? 0);
      setSkippedCount(saved.skippedCount ?? 0);
      setUnknownIdCount(saved.unknownOrDuplicateIdCount ?? 0);
      setRetryRound(saved.retryRound ?? 0);
      setUpdates(Array.isArray(saved.updates) ? saved.updates : []);
      setMerges(Array.isArray(saved.merges) ? saved.merges : []);
      const restoredUndetermined = Array.isArray(saved.undeterminedItems)
        ? saved.undeterminedItems
        : [];
      const restoredFailed = Array.isArray(saved.failedItems)
        ? saved.failedItems
        : [];
      const restoredBatchFailures = Array.isArray(saved.batchFailures)
        ? saved.batchFailures
        : [];
      setUndeterminedItems(restoredUndetermined);
      setFailedItems(restoredFailed);
      setBatchFailures(restoredBatchFailures);
      setLiveUndeterminedCount(restoredUndetermined.length);
      setLiveFailedCount(restoredFailed.length);
      setHasCompleted(true);
      setResumedFromDisk(true);
    });

    return () => {
      active = false;
    };
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !isAuditing) {
        onClose();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [open, isAuditing, onClose]);

  const currentCategoryItems = useMemo(
    () => catalogSnapshot.itemsByCategory[initialCategory] ?? [],
    [catalogSnapshot, initialCategory]
  );

  const targetItems =
    scope === "currentCategory" ? currentCategoryItems : allPendingGearItems;

  const selectedCount = useMemo(
    () =>
      updates.filter((u) => u.selected).length +
      merges.filter((m) => m.selected).length,
    [updates, merges]
  );

  if (!open) return null;

  const ready = isAIConfigReady(aiConfig);

  const handleClearSession = async () => {
    cancelledRef.current = true;
    await removePersistedSession();
    setHasCompleted(false);
    setResumedFromDisk(false);
    setErrorMessage(null);
    setInfoBanner(null);
    setModelUsed(null);
    setUpdates([]);
    setMerges([]);
    setUndeterminedItems([]);
    setFailedItems([]);
    setBatchFailures([]);
    setPlannedCount(0);
    setVerifiedCount(0);
    setSkippedCount(0);
    setUnknownIdCount(0);
    setLiveUndeterminedCount(0);
    setLiveFailedCount(0);
    setCurrentBatch(0);
    setTotalBatches(0);
    setRetryRound(0);
  };

  const updateProposalsAndPersist = (
    updater: (prev: GearAuditUpdateProposal[]) => GearAuditUpdateProposal[]
  ) => {
    setUpdates((prev) => {
      const next = updater(prev);
      if (hasCompleted) {
        persistSessionSnapshot({
          scope,
          modelUsed,
          plannedCount,
          verifiedCount,
          skippedCount,
          unknownIdCount,
          retryRound,
          updates: next,
          merges,
          undeterminedItems,
          failedItems,
          batchFailures,
        });
      }
      return next;
    });
  };

  const updateMergesAndPersist = (
    updater: (prev: GearAuditMergeProposal[]) => GearAuditMergeProposal[]
  ) => {
    setMerges((prev) => {
      const next = updater(prev);
      if (hasCompleted) {
        persistSessionSnapshot({
          scope,
          modelUsed,
          plannedCount,
          verifiedCount,
          skippedCount,
          unknownIdCount,
          retryRound,
          updates,
          merges: next,
          undeterminedItems,
          failedItems,
          batchFailures,
        });
      }
      return next;
    });
  };

  const runAudit = async () => {
    const itemsToAudit = targetItems;
    if (itemsToAudit.length === 0) return;

    cancelledRef.current = false;
    setIsAuditing(true);
    setHasCompleted(false);
    setResumedFromDisk(false);
    setErrorMessage(null);
    setInfoBanner(null);
    setUpdates([]);
    setMerges([]);
    setUndeterminedItems([]);
    setFailedItems([]);
    setBatchFailures([]);
    setPlannedCount(itemsToAudit.length);
    setVerifiedCount(0);
    setSkippedCount(0);
    setUnknownIdCount(0);
    setLiveUndeterminedCount(0);
    setLiveFailedCount(0);
    setCurrentBatch(0);
    setTotalBatches(0);
    setRetryRound(0);

    try {
      const report = await auditGearItems(itemsToAudit, aiConfig, isEnglish, {
        isCancelled: () => cancelledRef.current,
        onProgress: (p) => {
          setCurrentBatch(p.currentBatch);
          setTotalBatches(p.totalBatches);
          setVerifiedCount(p.verifiedCount);
          setLiveUndeterminedCount(p.undeterminedCount);
          setLiveFailedCount(p.failedCount);
          setSkippedCount(p.skippedCount);
        },
      });
      setUpdates(report.updates);
      setMerges(report.merges);
      setModelUsed(report.modelUsed);
      setPlannedCount(report.plannedCount);
      setVerifiedCount(report.verifiedCount);
      setUndeterminedItems(report.undeterminedItems);
      setFailedItems(report.failedItems);
      setSkippedCount(report.skippedCount);
      setUnknownIdCount(report.unknownOrDuplicateIdCount);
      setLiveUndeterminedCount(report.undeterminedItems.length);
      setLiveFailedCount(report.failedItems.length);
      setBatchFailures(report.failures);
      setHasCompleted(true);
      persistSessionSnapshot({
        scope,
        modelUsed: report.modelUsed,
        plannedCount: report.plannedCount,
        verifiedCount: report.verifiedCount,
        skippedCount: report.skippedCount,
        unknownIdCount: report.unknownOrDuplicateIdCount,
        retryRound: 0,
        updates: report.updates,
        merges: report.merges,
        undeterminedItems: report.undeterminedItems,
        failedItems: report.failedItems,
        batchFailures: report.failures,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setErrorMessage(msg);
    } finally {
      setIsAuditing(false);
    }
  };

  const runRetryFailedOnly = async () => {
    const retryingFailedOnly = failedItems.length > 0;
    const itemsToRetry = retryingFailedOnly ? [...failedItems] : [...undeterminedItems];
    if (itemsToRetry.length === 0 || retryRound >= MAX_RETRY_ROUNDS) return;

    cancelledRef.current = false;
    const nextRound = retryRound + 1;
    setRetryRound(nextRound);
    const baseVerified = verifiedCount;
    const baseSkipped = skippedCount;
    const baseBadIds = unknownIdCount;
    const baseUndetermined = retryingFailedOnly ? [...undeterminedItems] : [];

    setIsAuditing(true);
    setErrorMessage(null);
    setInfoBanner(null);
    setCurrentBatch(0);
    setTotalBatches(0);
    setLiveFailedCount(failedItems.length);

    try {
      const report = await auditGearItems(itemsToRetry, aiConfig, isEnglish, {
        isCancelled: () => cancelledRef.current,
        onProgress: (p) => {
          setCurrentBatch(p.currentBatch);
          setTotalBatches(p.totalBatches);
          setVerifiedCount(baseVerified + p.verifiedCount);
          setSkippedCount(baseSkipped + p.skippedCount);
          setLiveUndeterminedCount(
            baseUndetermined.length + p.undeterminedCount
          );
          setLiveFailedCount(p.failedCount);
        },
      });

      const nextVerified = baseVerified + report.verifiedCount;
      const nextSkipped = baseSkipped + report.skippedCount;
      const nextBadIds = baseBadIds + report.unknownOrDuplicateIdCount;

      const mergedUndetermined = [...baseUndetermined];
      for (const u of report.undeterminedItems) {
        if (!mergedUndetermined.some((x) => x.id === u.id)) {
          mergedUndetermined.push(u);
        }
      }

      const nextUpdates = [...updates];
      for (const u of report.updates) {
        const idx = nextUpdates.findIndex((ex) => ex.id === u.id);
        if (idx >= 0) {
          nextUpdates[idx] = u;
        } else {
          nextUpdates.push(u);
        }
      }

      const nextMerges = [...merges];
      for (const m of report.merges) {
        if (!nextMerges.some((ex) => ex.id === m.id)) {
          nextMerges.push(m);
        }
      }

      setModelUsed(report.modelUsed);
      setVerifiedCount(nextVerified);
      setSkippedCount(nextSkipped);
      setUnknownIdCount(nextBadIds);
      setUndeterminedItems(mergedUndetermined);
      setFailedItems(report.failedItems);
      setLiveUndeterminedCount(mergedUndetermined.length);
      setLiveFailedCount(report.failedItems.length);
      setBatchFailures(report.failures);
      setUpdates(nextUpdates);
      setMerges(nextMerges);
      setHasCompleted(true);
      setResumedFromDisk(false);

      persistSessionSnapshot({
        scope,
        modelUsed: report.modelUsed,
        plannedCount,
        verifiedCount: nextVerified,
        skippedCount: nextSkipped,
        unknownIdCount: nextBadIds,
        retryRound: nextRound,
        updates: nextUpdates,
        merges: nextMerges,
        undeterminedItems: mergedUndetermined,
        failedItems: report.failedItems,
        batchFailures: report.failures,
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      setErrorMessage(msg);
    } finally {
      setIsAuditing(false);
    }
  };

  const handleApply = async () => {
    if (isApplying || isReadOnlyProtected || selectedCount === 0) return;
    const appliedUpdateIds = new Set(
      updates.filter((u) => u.selected).map((u) => u.id)
    );
    const appliedMergeIds = new Set(
      merges.filter((m) => m.selected).map((m) => m.id)
    );
    const totalApplied = appliedUpdateIds.size + appliedMergeIds.size;

    setIsApplying(true);
    setErrorMessage(null);
    // 仅应用本次勾选的建议；原样保留所有未勾选待确认项与失败批次，不自动关闭弹窗
    const res = await applyAuditProposals(updates, merges, []);
    setIsApplying(false);

    if (res.ok) {
      const remainingUpdates = updates.filter(
        (u) => !appliedUpdateIds.has(u.id)
      );
      const remainingMerges = merges.filter((m) => !appliedMergeIds.has(m.id));
      setUpdates(remainingUpdates);
      setMerges(remainingMerges);
      setResumedFromDisk(false);

      persistSessionSnapshot({
        scope,
        modelUsed,
        plannedCount,
        verifiedCount,
        skippedCount,
        unknownIdCount,
        retryRound,
        updates: remainingUpdates,
        merges: remainingMerges,
        undeterminedItems,
        failedItems,
        batchFailures,
      });

      const remainProposals = remainingUpdates.length + remainingMerges.length;
      const remainIncomplete = failedItems.length + undeterminedItems.length;
      if (remainProposals === 0 && remainIncomplete === 0) {
        setInfoBanner(
          t(
            `已应用 ${totalApplied} 项修改，本次体检全部处理完毕。`,
            `Applied ${totalApplied} change(s). All audit items are now resolved.`,
            isEnglish
          )
        );
      } else {
        setInfoBanner(
          t(
            `已应用 ${totalApplied} 项修改；仍保留 ${remainProposals} 项未勾选建议与 ${remainIncomplete} 项未完成/失败项，可继续操作或点击「仅重试失败项」。`,
            `Applied ${totalApplied} change(s). ${remainProposals} unselected suggestion(s) and ${remainIncomplete} incomplete/failed item(s) remain preserved.`,
            isEnglish
          )
        );
      }
    } else if (res.error) {
      setErrorMessage(res.error);
    }
  };

  const displayedFailed = isAuditing ? liveFailedCount : failedItems.length;
  const displayedUndetermined = isAuditing
    ? liveUndeterminedCount
    : undeterminedItems.length;
  const retryableCount =
    failedItems.length > 0 ? failedItems.length : undeterminedItems.length;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/45 p-5 backdrop-blur-[2px]"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget && !isAuditing) onClose();
      }}
    >
      <div className="flex h-[84vh] max-h-[700px] w-full max-w-[780px] flex-col overflow-hidden rounded-2xl border border-[var(--wsj-border)] bg-[var(--wsj-canvas)] shadow-2xl">
        {/* 头部 */}
        <div className="flex items-center justify-between gap-3 border-b border-[var(--wsj-border)] bg-[var(--wsj-card)] px-6 py-4">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <Sparkles className="h-4 w-4 text-[var(--wsj-accent)]" />
              <h2 className="text-[18.5px] font-bold text-[var(--wsj-text)]">
                {t("AI 器材库体检", "AI Gear Audit", isEnglish)}
              </h2>
              {resumedFromDisk && hasCompleted && (
                <TagPill
                  text={t("已恢复上次进度", "Resumed Session", isEnglish)}
                  tone="forest"
                />
              )}
              {modelUsed && <TagPill text={modelUsed} tone="accent" />}
            </div>
            <p className="mt-1 text-[12.5px] text-[var(--wsj-text-secondary)]">
              {t(
                "应用勾选后不关闭弹窗，原样保留未勾选建议与失败批次；进度自动持久化至 ai_health_check_session.json，关闭或重启后自动断点续做。",
                "Applying keeps the modal open with remaining suggestions and failed batches intact. Session progress persists to ai_health_check_session.json.",
                isEnglish
              )}
            </p>
          </div>
          <button
            type="button"
            onClick={() => {
              cancelledRef.current = true;
              onClose();
            }}
            className="rounded-lg p-1.5 text-[var(--wsj-text-secondary)] hover:bg-[var(--wsj-subtle)] hover:text-[var(--wsj-text)]"
            aria-label="Close"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        {/* 主体 */}
        <div className="flex min-h-0 flex-1 flex-col gap-3.5 overflow-hidden p-5">
          {!ready ? (
            <div className="flex items-start gap-3 rounded-xl border border-[var(--wsj-accent)]/30 bg-[var(--wsj-accent-soft)] p-4">
              <Info className="mt-0.5 h-5 w-5 shrink-0 text-[var(--wsj-accent)]" />
              <div>
                <div className="text-[14px] font-semibold text-[var(--wsj-text)]">
                  {t(
                    "尚未启用 AI 识别接口",
                    "AI Recognition API is Not Enabled",
                    isEnglish
                  )}
                </div>
                <p className="mt-1 text-[12.5px] text-[var(--wsj-text-secondary)]">
                  {t(
                    "请先前往「外观与设置 → AI 识别接口」选择 DeepSeek 或自定义 OpenAI 兼容服务、保存 API Key 并开启总开关。",
                    "Go to Settings → AI Recognition API, save your API key, and enable the switch first.",
                    isEnglish
                  )}
                </p>
              </div>
            </div>
          ) : (
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div className="inline-flex rounded-[10px] bg-[var(--wsj-subtle)] p-1">
                <button
                  type="button"
                  disabled={isAuditing}
                  onClick={() => setScope("currentCategory")}
                  className={`rounded-lg px-3 py-1.5 text-[12.5px] font-medium transition ${
                    scope === "currentCategory"
                      ? "bg-[var(--wsj-card)] text-[var(--wsj-text)] shadow-sm"
                      : "text-[var(--wsj-text-secondary)] hover:text-[var(--wsj-text)]"
                  }`}
                >
                  {t(
                    `当前分类：${categoryPluralName(initialCategory, false)} (${currentCategoryItems.length})`,
                    `Current: ${categoryPluralName(initialCategory, true)} (${currentCategoryItems.length})`,
                    isEnglish
                  )}
                </button>
                <button
                  type="button"
                  disabled={isAuditing}
                  onClick={() => setScope("allPending")}
                  className={`rounded-lg px-3 py-1.5 text-[12.5px] font-medium transition ${
                    scope === "allPending"
                      ? "bg-[var(--wsj-card)] text-[var(--wsj-text)] shadow-sm"
                      : "text-[var(--wsj-text-secondary)] hover:text-[var(--wsj-text)]"
                  }`}
                >
                  {t(
                    `全部待确认 (${allPendingGearItems.length})`,
                    `All Pending (${allPendingGearItems.length})`,
                    isEnglish
                  )}
                </button>
              </div>

              <div className="flex items-center gap-2">
                {isAuditing ? (
                  <button
                    type="button"
                    onClick={() => {
                      cancelledRef.current = true;
                    }}
                    className="rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-card)] px-4 py-1.5 text-[13px] font-medium text-[var(--wsj-text)] hover:bg-[var(--wsj-subtle)]"
                  >
                    {t("取消体检", "Cancel Audit", isEnglish)}
                  </button>
                ) : (
                  <>
                    {hasCompleted && (
                      <button
                        type="button"
                        onClick={() => void handleClearSession()}
                        className="inline-flex items-center gap-1.5 rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-card)] px-3 py-1.5 text-[12.5px] font-medium text-[var(--wsj-text)] transition hover:bg-[var(--wsj-subtle)]"
                      >
                        <Trash2 className="h-3.5 w-3.5 text-[var(--wsj-text-secondary)]" />
                        {t("清空记录", "Clear Session", isEnglish)}
                      </button>
                    )}
                    <button
                      type="button"
                      disabled={targetItems.length === 0}
                      onClick={() => void runAudit()}
                      className="inline-flex items-center gap-1.5 rounded-lg bg-[var(--wsj-accent)] px-4 py-1.5 text-[13px] font-semibold text-white transition hover:opacity-90 disabled:opacity-45"
                    >
                      <Sparkles className="h-3.5 w-3.5" />
                      {hasCompleted
                        ? t("重新体检", "Re-Audit", isEnglish)
                        : t("开始 AI 体检", "Start Audit", isEnglish)}
                    </button>
                  </>
                )}
              </div>
            </div>
          )}

          {errorMessage && (
            <div className="flex items-center gap-2 rounded-lg bg-[#CC3D3D]/10 px-3 py-2 text-[12.5px] text-[#CC3D3D]">
              <AlertTriangle className="h-4 w-4 shrink-0" />
              <span className="break-words">{errorMessage}</span>
            </div>
          )}

          {infoBanner && (
            <div className="flex items-center justify-between gap-2 rounded-lg bg-[#2E8F5C]/12 px-3 py-2 text-[12.5px] text-[var(--wsj-text)]">
              <div className="flex items-center gap-2 min-w-0">
                <CheckCircle2 className="h-4 w-4 shrink-0 text-[#2E8F5C]" />
                <span className="break-words">{infoBanner}</span>
              </div>
              <button
                type="button"
                onClick={() => setInfoBanner(null)}
                className="shrink-0 rounded p-0.5 text-[var(--wsj-text-secondary)] hover:text-[var(--wsj-text)]"
                aria-label="Dismiss"
              >
                <X className="h-3.5 w-3.5" />
              </button>
            </div>
          )}

          {/* 实时状态胶囊与「仅重试失败项」 */}
          {(hasCompleted || isAuditing) && (
            <div className="flex flex-wrap items-center gap-2">
              <TagPill
                text={t(`计划 ${plannedCount}`, `Planned ${plannedCount}`, isEnglish)}
                tone="neutral"
              />
              <TagPill
                text={t(`成功核查 ${verifiedCount}`, `Verified ${verifiedCount}`, isEnglish)}
                tone="forest"
              />
              {displayedUndetermined > 0 && (
                <TagPill
                  text={t(
                    `待确认 ${displayedUndetermined}`,
                    `Uncertain ${displayedUndetermined}`,
                    isEnglish
                  )}
                  tone="amber"
                />
              )}
              <TagPill
                text={t(`失败 ${displayedFailed}`, `Failed ${displayedFailed}`, isEnglish)}
                tone={displayedFailed === 0 ? "slate" : "crimson"}
              />
              {skippedCount > 0 && (
                <TagPill
                  text={t(`无变更 ${skippedCount}`, `Unchanged ${skippedCount}`, isEnglish)}
                  tone="neutral"
                />
              )}
              {unknownIdCount > 0 && (
                <TagPill
                  text={t(`异常 ID ${unknownIdCount}`, `Bad IDs ${unknownIdCount}`, isEnglish)}
                  tone="crimson"
                />
              )}

              {!isAuditing && retryableCount > 0 && (
                <button
                  type="button"
                  disabled={retryRound >= MAX_RETRY_ROUNDS}
                  onClick={() => void runRetryFailedOnly()}
                  className="ml-auto inline-flex items-center gap-1.5 rounded-lg bg-[#D1851F] px-3 py-1 text-[12.5px] font-semibold text-white transition hover:opacity-90 disabled:opacity-45"
                >
                  <RotateCcw className="h-3.5 w-3.5" />
                  {retryRound >= MAX_RETRY_ROUNDS
                    ? t(
                        `已达重试上限 (${MAX_RETRY_ROUNDS})`,
                        `Retry Limit (${MAX_RETRY_ROUNDS})`,
                        isEnglish
                      )
                    : failedItems.length > 0
                      ? t(
                          `仅重试失败项 (${failedItems.length})`,
                          `Retry Failed Only (${failedItems.length})`,
                          isEnglish
                        )
                      : t(
                          `重试待确认项 (${undeterminedItems.length})`,
                          `Retry Uncertain (${undeterminedItems.length})`,
                          isEnglish
                        )}
                </button>
              )}
            </div>
          )}

          {/* 批次失败原因摘要 */}
          {!isAuditing && batchFailures.length > 0 && (
            <div className="rounded-xl border border-[#CC3D3D]/35 bg-[#CC3D3D]/8 p-3 text-[12px]">
              <div className="flex items-center gap-1.5 font-semibold text-[#CC3D3D]">
                <AlertTriangle className="h-3.5 w-3.5 shrink-0" />
                {t(
                  `有 ${batchFailures.length} 个批次（共 ${failedItems.length} 件器材）请求失败或被遗漏：`,
                  `${batchFailures.length} batch(es) (${failedItems.length} items) failed or omitted:`,
                  isEnglish
                )}
              </div>
              <div className="mt-1.5 space-y-1 text-[var(--wsj-text-secondary)]">
                {batchFailures.map((f, idx) => (
                  <div key={`${f.batchIndex}-${idx}`} className="truncate">
                    {t(
                      `• 第 ${f.batchIndex} 批（${f.items.length} 件）：${f.reason}`,
                      `• Batch #${f.batchIndex} (${f.items.length} items): ${f.reason}`,
                      isEnglish
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* 进度 / 空结果 / Diff 列表 */}
          <div className="min-h-0 flex-1 overflow-y-auto">
            {isAuditing ? (
              <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
                <Loader2 className="h-7 w-7 animate-spin text-[var(--wsj-accent)]" />
                <div className="text-[14px] font-medium text-[var(--wsj-text)]">
                  {totalBatches > 0
                    ? t(
                        `正在核验第 ${currentBatch} / ${totalBatches} 批（每批 6–8 件，单批超时 180 秒）...`,
                        `Auditing batch ${currentBatch} / ${totalBatches} (6–8 items/batch, 180s timeout)...`,
                        isEnglish
                      )
                    : t("正在调用 AI 核验器材参数...", "Auditing gear specs via AI...", isEnglish)}
                </div>
                {totalBatches > 0 && (
                  <div className="h-2 w-64 overflow-hidden rounded-full bg-[var(--wsj-subtle)]">
                    <div
                      className="h-full rounded-full bg-[var(--wsj-accent)] transition-all"
                      style={{
                        width: `${Math.min(100, Math.round((currentBatch / totalBatches) * 100))}%`,
                      }}
                    />
                  </div>
                )}
              </div>
            ) : hasCompleted &&
              updates.length === 0 &&
              merges.length === 0 &&
              failedItems.length === 0 &&
              undeterminedItems.length === 0 ? (
              <div className="flex h-full flex-col items-center justify-center gap-2 text-center">
                <CheckCircle2 className="h-9 w-9 text-[#2E8F5C]" />
                <p className="text-[14px] font-medium text-[var(--wsj-text-secondary)]">
                  {t(
                    "全部器材命名与参数已处理完毕，暂未发现需要修正或合并的条目",
                    "All checked items look clean — no fixes or merges remaining.",
                    isEnglish
                  )}
                </p>
              </div>
            ) : updates.length > 0 || merges.length > 0 ? (
              <div className="space-y-5 pr-1">
                {updates.length > 0 && (
                  <div className="space-y-2.5">
                    <div className="flex items-center justify-between">
                      <h3 className="text-[14.5px] font-semibold text-[var(--wsj-text)]">
                        {t(
                          `规范纠错与属性补全建议（${updates.length}）`,
                          `Naming & Spec Improvements (${updates.length})`,
                          isEnglish
                        )}
                      </h3>
                      <div className="flex items-center gap-3 text-[12px]">
                        <button
                          type="button"
                          onClick={() =>
                            updateProposalsAndPersist((prev) =>
                              prev.map((u) => ({ ...u, selected: true }))
                            )
                          }
                          className="font-medium text-[var(--wsj-accent)] hover:underline"
                        >
                          {t("全选", "Select All", isEnglish)}
                        </button>
                        <button
                          type="button"
                          onClick={() =>
                            updateProposalsAndPersist((prev) =>
                              prev.map((u) => ({ ...u, selected: false }))
                            )
                          }
                          className="font-medium text-[var(--wsj-text-secondary)] hover:underline"
                        >
                          {t("全不选", "Deselect All", isEnglish)}
                        </button>
                      </div>
                    </div>

                    {updates.map((prop) => (
                      <label
                        key={prop.id}
                        className="flex cursor-pointer items-start gap-3 rounded-xl border border-[var(--wsj-border)] bg-[var(--wsj-card)] p-3.5 transition hover:border-[var(--wsj-accent)]/40"
                      >
                        <input
                          type="checkbox"
                          checked={prop.selected}
                          onChange={(e) =>
                            updateProposalsAndPersist((prev) =>
                              prev.map((u) =>
                                u.id === prop.id
                                  ? { ...u, selected: e.target.checked }
                                  : u
                              )
                            )
                          }
                          className="mt-1 h-4 w-4 accent-[var(--wsj-accent)]"
                        />
                        <div className="min-w-0 flex-1 space-y-1.5">
                          <div className="flex flex-wrap items-center gap-2">
                            <span className="text-[13.5px] font-semibold text-[var(--wsj-text)]">
                              {brandDisplay(prop.item.brand, isEnglish)} ·{" "}
                              {prop.item.model}
                            </span>
                            <TagPill
                              text={`${Math.round(prop.confidence * 100)}%`}
                              tone={prop.confidence >= 0.72 ? "forest" : "amber"}
                            />
                            {prop.item.isManuallyConfirmed && (
                              <TagPill
                                text={t("已人工确认", "Manual", isEnglish)}
                                tone="slate"
                              />
                            )}
                          </div>
                          <div className="space-y-0.5 font-mono text-[12px] text-[var(--wsj-text)]">
                            {prop.changesSummary.map((line, i) => (
                              <div key={i}>• {line}</div>
                            ))}
                          </div>
                          <div className="text-[12px] text-[var(--wsj-text-secondary)]">
                            {prop.reason}
                          </div>
                        </div>
                      </label>
                    ))}
                  </div>
                )}

                {merges.length > 0 && (
                  <div className="space-y-2.5">
                    <h3 className="text-[14.5px] font-semibold text-[var(--wsj-text)]">
                      {t(
                        `疑似重复合并建议（${merges.length}）`,
                        `Suspected Duplicate Merges (${merges.length})`,
                        isEnglish
                      )}
                    </h3>

                    {merges.map((m) => (
                      <label
                        key={m.id}
                        className="flex cursor-pointer items-start gap-3 rounded-xl border border-[var(--wsj-border)] bg-[var(--wsj-card)] p-3.5 transition hover:border-[var(--wsj-accent)]/40"
                      >
                        <input
                          type="checkbox"
                          checked={m.selected}
                          onChange={(e) =>
                            updateMergesAndPersist((prev) =>
                              prev.map((x) =>
                                x.id === m.id
                                  ? { ...x, selected: e.target.checked }
                                  : x
                              )
                            )
                          }
                          className="mt-1 h-4 w-4 accent-[var(--wsj-accent)]"
                        />
                        <div className="min-w-0 flex-1 space-y-1">
                          <div className="flex flex-wrap items-center gap-1.5 text-[13.5px] font-semibold">
                            <span className="text-[var(--wsj-text)]">
                              {m.source.name}
                            </span>
                            <ArrowRight className="h-3.5 w-3.5 text-[var(--wsj-accent)]" />
                            <span className="text-[var(--wsj-accent)]">
                              {m.target.name}
                            </span>
                          </div>
                          <div className="text-[12px] text-[var(--wsj-text-secondary)]">
                            {m.reason}
                          </div>
                        </div>
                      </label>
                    ))}
                  </div>
                )}
              </div>
            ) : (
              <div className="flex h-full items-center justify-center px-6 text-center text-[13.5px] text-[var(--wsj-text-secondary)]">
                {hasCompleted
                  ? t(
                      "待应用建议已全部处理，但仍有失败或待确认条目，可直接点击上方「仅重试失败项」继续完成。",
                      "No pending suggestions left, but failed or uncertain items remain. Click Retry above to continue.",
                      isEnglish
                    )
                  : t(
                      "选择范围后点击「开始 AI 体检」查看逐项修改建议（Diff）",
                      "Choose a scope and click Start Audit to review proposed diffs",
                      isEnglish
                    )}
              </div>
            )}
          </div>
        </div>

        {/* 底部操作栏 */}
        <div className="flex items-center justify-between gap-3 border-t border-[var(--wsj-border)] bg-[var(--wsj-card)] px-6 py-3.5">
          <div className="text-[12.5px] text-[var(--wsj-text-secondary)]">
            {hasCompleted && (updates.length > 0 || merges.length > 0)
              ? t(
                  `已勾选 ${selectedCount} 项改动（应用后保留未勾选与失败项，可随时撤销）`,
                  `${selectedCount} selected (unselected & failed items preserved; undoable)`,
                  isEnglish
                )
              : ""}
          </div>

          <div className="flex items-center gap-2.5">
            <button
              type="button"
              onClick={() => {
                cancelledRef.current = true;
                onClose();
              }}
              className="rounded-lg border border-[var(--wsj-border)] bg-[var(--wsj-subtle)] px-4 py-1.5 text-[13px] font-medium text-[var(--wsj-text)] hover:opacity-85"
            >
              {t("关闭", "Close", isEnglish)}
            </button>

            {(updates.length > 0 || merges.length > 0) && (
              <button
                type="button"
                disabled={
                  selectedCount === 0 ||
                  isReadOnlyProtected ||
                  isAuditing ||
                  isApplying
                }
                onClick={() => void handleApply()}
                className="rounded-lg bg-[var(--wsj-accent)] px-4 py-1.5 text-[13px] font-semibold text-white transition hover:opacity-90 disabled:opacity-45"
              >
                {t("应用选中修改", "Apply Selected", isEnglish)}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
};
