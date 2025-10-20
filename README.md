# K3s Pod Timing Experiment

K3s 환경에서 재부팅을 통한 pod 시작 시간 측정 실험 프로젝트입니다.

## 실험 개요

이 실험은 K3s 환경에서 pod가 재시작될 때마다 `clock_gettime(CLOCK_MONOTONIC)`으로 측정한 시작 시간을 기록하여, 시스템 재부팅에 따른 시간 변화를 관찰합니다.

### 실험 변인

- **이미지 타입**: Ubuntu 22.04, ROS2 Humble-ros-base
- **Pod 개수**: 8개, 16개
- **총 4가지 조합**

### 고정 인자

- **Pod Restart Policy**: Always
- **재부팅 횟수**: 20번
- **Core-ID Annotation**: "8-15" (모든 케이스 공통)

## 프로젝트 구조

```
phase-experiment/
├── timing_app.cpp              # C++ 타이밍 측정 애플리케이션
├── Dockerfile.ubuntu           # Ubuntu 22.04 이미지용 Dockerfile
├── Dockerfile.ros2             # ROS2 Humble 이미지용 Dockerfile
├── k8s/                        # Kubernetes 배포 YAML 파일들
│   ├── deployment-ubuntu-8pods.yaml
│   ├── deployment-ubuntu-16pods.yaml
│   ├── deployment-ros2-8pods.yaml
│   └── deployment-ros2-16pods.yaml
├── run_experiment.sh           # 실험 오케스트레이션 스크립트
└── README.md                   # 이 파일
```

## 사전 요구사항

1. **K3s 설치 및 실행 중**
   ```bash
   systemctl status k3s
   ```

2. **Docker 설치**
   ```bash
   docker --version
   ```

3. **kubectl 설치 및 K3s와 연결**
   ```bash
   kubectl get nodes
   ```

4. **시스템 권한**
   - 재부팅을 위한 root 권한 필요
   - K3s는 systemd로 자동 재시작 설정 필요

## 사용 방법

### 1. 모든 실험 자동 실행

```bash
./run_experiment.sh
```

이 스크립트는 다음을 자동으로 수행합니다:
1. Docker 이미지 빌드 (Ubuntu, ROS2)
2. 이미지를 K3s로 import
3. 4가지 실험 구성을 순차적으로 실행
4. 각 실험마다 20번의 재부팅 수행
5. 결과를 `./experiment-results/` 디렉토리에 저장

### 2. 개별 실험 실행

#### Step 1: 이미지 빌드

```bash
# Ubuntu 이미지
docker build -t timing-experiment:ubuntu -f Dockerfile.ubuntu .

# ROS2 이미지
docker build -t timing-experiment:ros2 -f Dockerfile.ros2 .
```

#### Step 2: K3s로 이미지 import

```bash
# Ubuntu 이미지
docker save timing-experiment:ubuntu -o /tmp/timing-ubuntu.tar
sudo k3s ctr images import /tmp/timing-ubuntu.tar

# ROS2 이미지
docker save timing-experiment:ros2 -o /tmp/timing-ros2.tar
sudo k3s ctr images import /tmp/timing-ros2.tar
```

#### Step 3: 특정 실험 배포

```bash
# 예: Ubuntu 8 pods 실험
kubectl apply -f k8s/deployment-ubuntu-8pods.yaml

# Pod 상태 확인
kubectl get pods -n timing-experiment

# 로그 확인
kubectl logs -n timing-experiment timing-pod-ubuntu-8-0
```

#### Step 4: 실험 데이터 확인

```bash
# 호스트 경로에서 데이터 확인
sudo ls -la /mnt/experiment-data/ubuntu-8pods/logs/

# 실험 진행 상황 확인
sudo cat /mnt/experiment-data/ubuntu-8pods/experiment_count.txt
```

#### Step 5: 실험 종료 및 정리

```bash
kubectl delete -f k8s/deployment-ubuntu-8pods.yaml
```

## 애플리케이션 동작 방식

### timing_app.cpp

1. **시작 시간 측정**: `clock_gettime(CLOCK_MONOTONIC)`으로 현재 시간 측정
2. **실험 번호 확인**: `/shared/experiment_count.txt`에서 현재 실험 번호 읽기
3. **데이터 기록**:
   - Pod별 임시 파일 생성: `/shared/<pod-name>.txt`
   - 실험 번호, Pod 이름, 시작 시간 기록
4. **로그 저장**:
   - 로그 디렉토리로 복사: `/shared/logs/exp<N>_<pod-name>.txt`
   - 임시 파일 삭제
5. **실험 진행**:
   - 실험 횟수 < 20: 카운터 증가 후 시스템 재부팅
   - 실험 횟수 >= 20: 실험 완료, Pod 유지 (무한 대기)

## 데이터 형식

각 로그 파일 (`exp<N>_<pod-name>.txt`)은 다음 형식을 가집니다:

```
experiment=0
pod=timing-pod-ubuntu-8-0
start_time_sec=12345
start_time_nsec=678901234
```

## K8s 리소스 구성

### PersistentVolume & PersistentVolumeClaim

- **Type**: hostPath
- **Access Mode**: ReadWriteMany
- **Path**: `/mnt/experiment-data/<config-name>/`
- 각 실험 구성마다 독립적인 PV/PVC 사용

### StatefulSet

- **Replicas**: 8 또는 16
- **Restart Policy**: Always
- **Security Context**:
  - Privileged: true (재부팅 권한)
  - SYS_BOOT capability 추가
- **Annotations**: `core-id: "8-15"` (모든 Pod)

## 결과 분석

실험 완료 후 `./experiment-results/` 디렉토리에 다음이 저장됩니다:

```
experiment-results/
├── ubuntu-8pods_20250121_100000/
│   ├── logs/
│   │   ├── exp0_timing-pod-ubuntu-8-0.txt
│   │   ├── exp0_timing-pod-ubuntu-8-1.txt
│   │   ├── ...
│   │   ├── exp19_timing-pod-ubuntu-8-0.txt
│   │   └── exp19_timing-pod-ubuntu-8-7.txt
│   ├── experiment_count.txt
│   └── summary.txt
├── ubuntu-16pods_20250121_120000/
├── ros2-8pods_20250121_140000/
├── ros2-16pods_20250121_160000/
└── final_summary.txt
```

### 데이터 분석 예시

```bash
# 특정 Pod의 모든 실험 결과 확인
grep "start_time_sec" experiment-results/ubuntu-8pods_*/logs/exp*_timing-pod-ubuntu-8-0.txt

# 실험별 파일 개수 확인
for dir in experiment-results/*/logs; do
    echo "$(dirname $dir): $(ls -1 $dir | wc -l) files"
done
```

## 주의사항

1. **재부팅 권한**: Pod가 시스템을 재부팅하려면 privileged 모드와 SYS_BOOT capability가 필요합니다.

2. **K3s 자동 재시작**: K3s가 systemd로 관리되어 재부팅 후 자동으로 시작되어야 합니다.
   ```bash
   sudo systemctl enable k3s
   ```

3. **데이터 지속성**: hostPath를 사용하므로 호스트 시스템의 `/mnt/experiment-data/` 디렉토리가 재부팅 후에도 유지됩니다.

4. **실험 시간**: 각 실험은 약 20번의 재부팅이 필요하므로, 재부팅당 2-5분 소요 시 총 40-100분이 걸릴 수 있습니다.

5. **디스크 공간**: 각 실험당 약 10-20MB 정도의 로그 데이터가 생성됩니다.

## 트러블슈팅

### Pod가 시작하지 않는 경우

```bash
kubectl describe pod -n timing-experiment <pod-name>
kubectl logs -n timing-experiment <pod-name>
```

### 이미지를 찾을 수 없는 경우

```bash
# K3s에 import된 이미지 확인
sudo k3s ctr images list | grep timing-experiment

# 다시 import
docker save timing-experiment:ubuntu -o /tmp/timing-ubuntu.tar
sudo k3s ctr images import /tmp/timing-ubuntu.tar
```

### 재부팅이 동작하지 않는 경우

- Pod의 securityContext가 privileged: true인지 확인
- SYS_BOOT capability가 추가되었는지 확인
- 호스트 시스템의 권한 설정 확인

### PV/PVC 문제

```bash
# PV/PVC 상태 확인
kubectl get pv
kubectl get pvc -n timing-experiment

# 호스트 디렉토리 권한 확인
sudo ls -la /mnt/experiment-data/

# 권한 수정
sudo chmod 777 /mnt/experiment-data/ubuntu-8pods/
```

## 라이선스

이 프로젝트는 실험 목적으로 제공됩니다.
