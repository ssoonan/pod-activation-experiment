#!/usr/bin/env python3
"""
실험 결과 분석 스크립트
- 각 실험별 max spread 및 표준편차 계산
- 전체 실험 그룹별 box plot 생성
"""

import os
import re
from pathlib import Path
from collections import defaultdict
import numpy as np
import matplotlib.pyplot as plt
import matplotlib
matplotlib.use('Agg')  # GUI 없이 사용

# 결과 디렉토리 설정
RESULTS_DIR = Path("experiment-results")
OUTPUT_DIR = Path("analysis-results")
OUTPUT_DIR.mkdir(exist_ok=True)


def parse_timing_file(file_path):
    """
    타이밍 파일을 파싱하여 ms 단위로 변환

    Returns:
        float: 시작 시간 (ms)
    """
    with open(file_path, 'r') as f:
        content = f.read()

    # sec와 nsec 추출
    sec_match = re.search(r'start_time_sec=(\d+)', content)
    nsec_match = re.search(r'start_time_nsec=(\d+)', content)

    if sec_match and nsec_match:
        sec = int(sec_match.group(1))
        nsec = int(nsec_match.group(1))
        # ms로 변환: sec * 1000 + nsec / 1000000
        time_ms = sec * 1000 + nsec / 1_000_000
        return time_ms

    return None


def analyze_experiment(exp_dir):
    """
    개별 실험 디렉토리 분석

    Returns:
        dict: {
            'times_ms': list of times,
            'max_spread': float,
            'std': float,
            'min': float,
            'max': float
        }
    """
    times_ms = []

    # 모든 timing 파일 읽기
    for timing_file in exp_dir.glob("timing-*.txt"):
        time_ms = parse_timing_file(timing_file)
        if time_ms is not None:
            times_ms.append(time_ms)

    if not times_ms:
        return None

    times_array = np.array(times_ms)

    return {
        'times_ms': times_ms,
        'max_spread': np.max(times_array) - np.min(times_array),
        'std': np.std(times_ms, ddof=1),  # 표본 표준편차
        'min': np.min(times_array),
        'max': np.max(times_array),
        'count': len(times_ms)
    }


def main():
    # 전체 데이터 구조: {experiment_group: {exp_name: stats}}
    all_experiments = defaultdict(dict)

    # 모든 실험 그룹 디렉토리 탐색
    for exp_group_dir in sorted(RESULTS_DIR.iterdir()):
        if not exp_group_dir.is_dir():
            continue

        exp_group_name = exp_group_dir.name
        print(f"\n분석 중: {exp_group_name}")

        # 각 실험 (exp0, exp1, ...) 분석
        for exp_dir in sorted(exp_group_dir.iterdir()):
            if not exp_dir.is_dir() or not exp_dir.name.startswith('exp'):
                continue

            exp_name = exp_dir.name
            stats = analyze_experiment(exp_dir)

            if stats:
                all_experiments[exp_group_name][exp_name] = stats
                print(f"  {exp_name}: {stats['count']} pods, "
                      f"max_spread={stats['max_spread']:.3f}ms, "
                      f"std={stats['std']:.3f}ms")

    # 1. 개별 실험별 텍스트 결과 저장
    output_text_file = OUTPUT_DIR / "individual_experiment_stats.txt"
    with open(output_text_file, 'w', encoding='utf-8') as f:
        f.write("=" * 80 + "\n")
        f.write("개별 실험 통계 (Individual Experiment Statistics)\n")
        f.write("=" * 80 + "\n\n")

        for exp_group_name in sorted(all_experiments.keys()):
            f.write(f"\n{'=' * 80}\n")
            f.write(f"실험 그룹: {exp_group_name}\n")
            f.write(f"{'=' * 80}\n\n")

            for exp_name in sorted(all_experiments[exp_group_name].keys()):
                stats = all_experiments[exp_group_name][exp_name]
                f.write(f"  [{exp_name}]\n")
                f.write(f"    Pod 개수:        {stats['count']}\n")
                f.write(f"    최소 시작 시간:  {stats['min']:.6f} ms\n")
                f.write(f"    최대 시작 시간:  {stats['max']:.6f} ms\n")
                f.write(f"    Max Spread:      {stats['max_spread']:.6f} ms\n")
                f.write(f"    표준편차 (Std):  {stats['std']:.6f} ms\n")
                f.write(f"\n")

    print(f"\n개별 실험 통계 저장: {output_text_file}")

    # 2. 전체 실험 그룹별 Box Plot 생성
    # 2-1. Max Spread Box Plot
    fig, ax = plt.subplots(figsize=(12, 6))

    spread_data = []
    labels = []

    for exp_group_name in sorted(all_experiments.keys()):
        spreads = [stats['max_spread']
                   for stats in all_experiments[exp_group_name].values()]
        spread_data.append(spreads)
        labels.append(exp_group_name)

    bp = ax.boxplot(spread_data, labels=labels, patch_artist=True)

    # 색상 설정
    for patch in bp['boxes']:
        patch.set_facecolor('lightblue')

    ax.set_ylabel('Max Spread (ms)', fontsize=12)
    ax.set_xlabel('Experiment Group', fontsize=12)
    ax.set_title('Max Spread Distribution Across Experiment Groups', fontsize=14, fontweight='bold')
    ax.grid(True, alpha=0.3)
    plt.xticks(rotation=45, ha='right')
    plt.tight_layout()

    spread_plot_file = OUTPUT_DIR / "max_spread_boxplot.png"
    plt.savefig(spread_plot_file, dpi=300, bbox_inches='tight')
    print(f"Max Spread Box Plot 저장: {spread_plot_file}")
    plt.close()

    # 2-2. Standard Deviation Box Plot
    fig, ax = plt.subplots(figsize=(12, 6))

    std_data = []

    for exp_group_name in sorted(all_experiments.keys()):
        stds = [stats['std']
                for stats in all_experiments[exp_group_name].values()]
        std_data.append(stds)

    bp = ax.boxplot(std_data, labels=labels, patch_artist=True)

    # 색상 설정
    for patch in bp['boxes']:
        patch.set_facecolor('lightgreen')

    ax.set_ylabel('Standard Deviation (ms)', fontsize=12)
    ax.set_xlabel('Experiment Group', fontsize=12)
    ax.set_title('Standard Deviation Distribution Across Experiment Groups', fontsize=14, fontweight='bold')
    ax.grid(True, alpha=0.3)
    plt.xticks(rotation=45, ha='right')
    plt.tight_layout()

    std_plot_file = OUTPUT_DIR / "std_boxplot.png"
    plt.savefig(std_plot_file, dpi=300, bbox_inches='tight')
    print(f"Standard Deviation Box Plot 저장: {std_plot_file}")
    plt.close()

    # 3. 전체 요약 통계
    summary_file = OUTPUT_DIR / "summary_stats.txt"
    with open(summary_file, 'w', encoding='utf-8') as f:
        f.write("=" * 80 + "\n")
        f.write("전체 실험 그룹 요약 통계 (Summary Statistics)\n")
        f.write("=" * 80 + "\n\n")

        for exp_group_name in sorted(all_experiments.keys()):
            spreads = [stats['max_spread']
                       for stats in all_experiments[exp_group_name].values()]
            stds = [stats['std']
                    for stats in all_experiments[exp_group_name].values()]

            f.write(f"\n[{exp_group_name}]\n")
            f.write(f"  실험 횟수: {len(spreads)}\n")
            f.write(f"  Max Spread:\n")
            f.write(f"    평균:     {np.mean(spreads):.6f} ms\n")
            f.write(f"    중앙값:   {np.median(spreads):.6f} ms\n")
            f.write(f"    최소:     {np.min(spreads):.6f} ms\n")
            f.write(f"    최대:     {np.max(spreads):.6f} ms\n")
            f.write(f"  Standard Deviation:\n")
            f.write(f"    평균:     {np.mean(stds):.6f} ms\n")
            f.write(f"    중앙값:   {np.median(stds):.6f} ms\n")
            f.write(f"    최소:     {np.min(stds):.6f} ms\n")
            f.write(f"    최대:     {np.max(stds):.6f} ms\n")
            f.write(f"\n")

    print(f"전체 요약 통계 저장: {summary_file}")
    print(f"\n분석 완료! 결과는 '{OUTPUT_DIR}' 디렉토리에 저장되었습니다.")


if __name__ == "__main__":
    main()
