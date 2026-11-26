import React from "react";
import type { BladeType, GearCategory, RazorType } from "../../types/journal";

interface GearSilhouetteProps {
  category: GearCategory;
  razorType?: RazorType;
  bladeType?: BladeType;
  size?: number;
  className?: string;
}

/** 器材品类/子类扁平矢量水印剪影（纯 SVG，与 Mac 版 SwiftUI Shape 视觉 1:1 对齐，自动适配浅色/深色模式） */
export const GearSilhouette: React.FC<GearSilhouetteProps> = ({
  category,
  razorType,
  bladeType,
  size = 68,
  className = "",
}) => {
  const renderShape = () => {
    if (category === "刀片") {
      if (bladeType === "AC") {
        return (
          <path
            fillRule="evenodd"
            d="M10 39 Q10 36 16 36 L84 36 Q90 36 90 39 L92 63 L8 63 Z M24 45 H28 A3 3 0 0 1 28 51 H24 A3 3 0 0 1 24 45 Z M46 45 H54 A3 3 0 0 1 54 51 H46 A3 3 0 0 1 46 45 Z M72 45 H76 A3 3 0 0 1 76 51 H72 A3 3 0 0 1 72 45 Z"
          />
        );
      }
      if (bladeType === "GEM") {
        return (
          <>
            <rect x="11" y="27" width="78" height="13" rx="3" />
            <path
              fillRule="evenodd"
              d="M15 42 H85 V50 H80 V57 H87 L89 73 H11 L13 57 H20 V50 H15 Z M50 50 A4 4 0 1 0 50.01 50 Z"
            />
          </>
        );
      }
      if (bladeType === "Injector") {
        return (
          <path
            fillRule="evenodd"
            d="M10 41 H90 L92 47 H88 V53 H92 L90 60 H10 L8 53 H12 V47 H8 Z M28.25 48 H71.75 A2.25 2.25 0 0 1 71.75 52.5 H28.25 A2.25 2.25 0 0 1 28.25 48 Z"
          />
        );
      }
      if (bladeType === "盒刀头") {
        return (
          <>
            <path
              fillRule="evenodd"
              d="M21 26 H79 A8 8 0 0 1 87 34 V57 A8 8 0 0 1 79 65 H21 A8 8 0 0 1 13 57 V34 A8 8 0 0 1 21 26 Z M23 34 H77 A2 2 0 0 1 77 38.5 H23 A2 2 0 0 1 23 34 Z M23 43 H77 A2 2 0 0 1 77 47.5 H23 A2 2 0 0 1 23 43 Z M23 52 H77 A2 2 0 0 1 77 56.5 H23 A2 2 0 0 1 23 52 Z"
            />
            <rect x="41" y="67" width="18" height="10" rx="3" />
          </>
        );
      }
      if (bladeType === "其他") {
        return (
          <path
            fillRule="evenodd"
            d="M16 34 H84 L90 66 H10 Z M50 45 A5 5 0 1 0 50.01 45 Z"
          />
        );
      }
      // 默认 DE 双面刀片（四角缺口 + 中央镂空槽）
      return (
        <path
          fillRule="evenodd"
          d="M16 27 H84 V34 H91 V44 H87 V56 H91 V66 H84 V73 H16 V66 H9 V56 H13 V44 H9 V34 H16 Z M27 47 H73 A3 3 0 0 1 73 53 H27 A3 3 0 0 1 27 47 Z M33 43 A7 7 0 1 0 33.01 43 Z M67 43 A7 7 0 1 0 67.01 43 Z M48 41 H52 A3 3 0 0 1 55 44 V56 A3 3 0 0 1 52 59 H48 A3 3 0 0 1 45 56 V44 A3 3 0 0 1 48 41 Z"
        />
      );
    }

    if (category === "剃须刀") {
      if (razorType === "直剃" || razorType === "替刃") {
        return (
          <>
            <path d="M10 40 Q14 48 22 45 L34 39 L84 17 Q90 18 90 24 L91 31 L39 50 Q31 53 24 51 L12 45 Z" />
            <path
              fillRule="evenodd"
              d="M24 55 Q27 51 33 53 L86 74 Q92 81 82 87 L25 63 Q20 59 24 55 Z M28.25 55.5 A2.25 2.25 0 1 0 28.26 55.5 Z"
            />
          </>
        );
      }
      if (razorType === "盒刀") {
        return (
          <>
            <path
              fillRule="evenodd"
              d="M27 14 H73 A5 5 0 0 1 78 19 V29 A5 5 0 0 1 73 34 H27 A5 5 0 0 1 22 29 V19 A5 5 0 0 1 27 14 Z M29.5 20 H70.5 A1.5 1.5 0 0 1 70.5 23 H29.5 A1.5 1.5 0 0 1 29.5 20 Z M29.5 26 H70.5 A1.5 1.5 0 0 1 70.5 29 H29.5 A1.5 1.5 0 0 1 29.5 26 Z"
            />
            <path d="M42 36 H58 L55 48 C59 60 60 72 58 82 Q56 92 50 92 Q44 92 42 82 C40 72 41 60 45 48 Z" />
          </>
        );
      }
      // 默认安全刀（T 字形）
      return (
        <>
          <path d="M17 20 Q50 9 83 20 L85 26 Q85 31 80 31 H20 Q15 31 15 26 Z" />
          <rect x="41" y="33" width="18" height="6" rx="2.5" />
          <path d="M44 41 H56 L57.5 82 Q59.5 85 59 88 Q58 93 50 93 Q42 93 41 88 Q40.5 85 42.5 82 Z" />
        </>
      );
    }

    if (category === "剃须刷") {
      return (
        <>
          <path d="M31 50 C16 35 26 11 50 11 C74 11 84 35 69 50 Z" />
          <path d="M33 54 H67 C59 66 72 76 68 88 Q68 91 64 91 H36 Q32 91 32 88 C28 76 41 66 33 54 Z" />
        </>
      );
    }

    if (category === "剃须皂") {
      return (
        <>
          <ellipse cx="45" cy="24.5" rx="11" ry="7.5" />
          <ellipse cx="58" cy="27" rx="8" ry="6" />
          <ellipse cx="33" cy="28" rx="7" ry="5" />
          <rect x="13" y="36" width="74" height="11" rx="5" />
          <path
            fillRule="evenodd"
            d="M25 50 H75 A9 9 0 0 1 84 59 V75 A9 9 0 0 1 75 84 H25 A9 9 0 0 1 16 75 V59 A9 9 0 0 1 25 50 Z M37 61 H63 A4 4 0 0 1 67 65 V69 A4 4 0 0 1 63 73 H37 A4 4 0 0 1 33 69 V65 A4 4 0 0 1 37 61 Z"
          />
        </>
      );
    }

    if (category === "须前") {
      return (
        <>
          <rect x="44" y="11" width="12" height="16" rx="6" />
          <rect x="38" y="29" width="24" height="8" rx="3" />
          <path
            fillRule="evenodd"
            d="M41 39 H59 C68 42 72 48 72 56 V84 Q72 90 65 90 H35 Q28 90 28 84 V56 C28 48 32 42 41 39 Z M50 56 C55 63 58 66 58 70 A8 8 0 0 1 42 70 C42 66 45 63 50 56 Z"
          />
        </>
      );
    }

    if (category === "须后") {
      return (
        <>
          <rect x="39" y="12" width="22" height="13" rx="4" />
          <rect x="43" y="27" width="14" height="9" />
          <path
            fillRule="evenodd"
            d="M33 37 H67 A10 10 0 0 1 77 47 V80 A10 10 0 0 1 67 90 H33 A10 10 0 0 1 23 80 V47 A10 10 0 0 1 33 37 Z M38 52 H62 A4 4 0 0 1 66 56 V70 A4 4 0 0 1 62 74 H38 A4 4 0 0 1 34 70 V56 A4 4 0 0 1 38 52 Z"
          />
        </>
      );
    }

    // 剃须碗
    return (
      <>
        <rect x="11" y="36" width="68" height="7" rx="3.5" />
        <path d="M15 45 H75 C74 62 68 72 61 76 H29 C22 72 16 62 15 45 Z" />
        <rect x="31" y="78" width="28" height="6" rx="3" />
        <path
          fillRule="evenodd"
          d="M81.5 47 A8.5 9.5 0 1 0 81.51 47 Z M81.5 51.5 A4 5 0 1 1 81.49 51.5 Z"
        />
      </>
    );
  };

  return (
    <svg
      viewBox="0 0 100 100"
      width={size}
      height={size}
      fill="currentColor"
      aria-hidden="true"
      className={`pointer-events-none select-none text-[var(--wsj-text)]/[0.055] dark:text-white/[0.075] ${className}`}
    >
      {renderShape()}
    </svg>
  );
};
