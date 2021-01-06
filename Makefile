GRAFANA_ADMIN_PASSWORD = s3cre7
ROOT_DOMAIN = demo.local
NAMESPACE = prometheus-monitoring
TEAMSPROXY_URL = changeme
SLACK_URL = changeme
SMTP_RELAY = changeme
SMTP_MAILFROM = alertmanager@demo.local
SMTP_MAILTO = changeme

apicheck:
	if ! kubectl get ns >/dev/null 2>&1; then \
	    echo FATAL: Failed querying namespaces: check k8s connectivity; \
	    exit 1; \
	fi

nscheck: apicheck
	if ! kubectl get ns $(NAMESPACE) >/dev/null 2>&1; then \
	    if ! kubectl create ns $(NAMESPACE); then \
		echo FATAL: Failed creating $(NAMESPACE) namespace; \
		exit 1; \
	    fi; \
	fi

alertmanager: apicheck
	SC=`kubectl get sc 2>/dev/null | awk 'NR>1{print $$1;exit;}'`; \
	if test -z "$$SC"; then \
	    echo WARNING: Did not find StorageClass: assuming ephemeral deployment; \
	    AMFILE=alertmanager-statefulset-volatile.yaml; \
	else \
	    AMFILE=alertmanager-statefulset.yaml; \
	fi; \
	if test "$(TEAMSPROXY_URL)" != changeme; then \
	    kubectl apply -n $(NAMESPACE) -f teamsproxy-deployment.yaml; \
	    kubectl apply -n $(NAMESPACE) -f teamsproxy-service.yaml; \
	    sed -e "s|TEAMSPROXY_URL_SED|$(TEAMSPROXY_URL)|" \
		-e "s|NAMESPACE_SED|$(NAMESPACE)|" \
		alertmanager-secret-teams.yaml \
		| kubectl apply -n $(NAMESPACE) -f-; \
	    sed "s|NAMESPACE_SED|$(NAMESPACE)|" $$AMFILE \
		| kubectl apply -n $(NAMESPACE) -f-; \
	    kubectl apply -n $(NAMESPACE) -f alertmanager-service.yaml; \
	    kubectl apply -n $(NAMESPACE) -f alertmanager-exporter-service.yaml; \
	    sed "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" alertmanager-ingress.yaml \
		| kubectl apply -n $(NAMESPACE) -f-; \
	elif test "$(SLACK_URL)" != changeme; then \
	    sed "s|SLACK_URL_SED|$(SLACK_URL)|" \
		alertmanager-secret-slack.yaml \
		| kubectl apply -n $(NAMESPACE) -f-; \
	    sed "s|NAMESPACE_SED|$(NAMESPACE)|" $$AMFILE \
		| kubectl apply -n $(NAMESPACE) -f-; \
	    kubectl apply -n $(NAMESPACE) -f alertmanager-service.yaml; \
	    kubectl apply -n $(NAMESPACE) -f alertmanager-exporter-service.yaml; \
	    sed "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" alertmanager-ingress.yaml \
		| kubectl apply -n $(NAMESPACE) -f-; \
	elif test "$(SMTP_RELAY)" != changeme -a "$(SMTP_MAILTO)" != changeme; then \
	    sed -e "s|MAILFROM_SED|$(SMTP_MAILFROM)|" \
		-e "s|MAILRELAY_SED|$(SMTP_RELAY)|" \
		-e "s|MAILTO_SED|$(SMTP_MAILTO)|" \
		alertmanager-secret-mails.yaml \
		| kubectl apply -n $(NAMESPACE) -f-; \
	    sed "s|NAMESPACE_SED|$(NAMESPACE)|" $$AMFILE \
		| kubectl apply -n $(NAMESPACE) -f-; \
	    kubectl apply -n $(NAMESPACE) -f alertmanager-service.yaml; \
	    kubectl apply -n $(NAMESPACE) -f alertmanager-exporter-service.yaml; \
	    sed "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" alertmanager-ingress.yaml \
		| kubectl apply -n $(NAMESPACE) -f-; \
	else \
	    echo WARN: Ignoring AlertManager deployment as notifications method was; \
	    echo WARN: not configured. Define either SMTP_RELAY+SMTP_MAILTO, SLACK_URL; \
	    echo WARN: or TEAMSPROXY_URL variables; \
	fi

grafana-config:
	find grafana-dashboards.d/ -type f -name '*.json' \
	    | cut -d/ -f2 \
	    | while read file; \
	    do \
		cmname=`echo "$$file" | tr [A-Z] [a-z] | sed -e 's|[_-]||g' -e 's|\.json\$$||'`; \
		kubectl get cm -n $(NAMESPACE) grafana-dashboard-$$cmname \
		    >/dev/null 2>&1 && continue; \
		kubectl create cm -n $(NAMESPACE) grafana-dashboard-$$cmname \
		    --from-file=$$file=./grafana-dashboards.d/$$file; \
	    done
	sed -e "s|GRAFANA_ADMIN_PASSWORD|$(GRAFANA_ADMIN_PASSWORD)|" \
	    -e "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" grafana-secret.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-

ifeq ($(DO_THANOS),yes)
grafana: apicheck grafana-config
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" grafana-thanos-configmap.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
	kubectl apply -n $(NAMESPACE) -f grafana-deployment.yaml
	kubectl apply -n $(NAMESPACE) -f grafana-service.yaml
	sed "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" grafana-ingress.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-

minio: apicheck
	if ! kubectl get secret -n $(NAMESPACE) minio-admin >/dev/null 2>&1; then \
	    MINIO_ADMIN_AK=`tr -d -c a-z0-9 </dev/urandom 2>/dev/null | head -c 19`; \
	    MINIO_ADMIN_SK=`tr -d -c a-z0-9 </dev/urandom 2>/dev/null | head -c 41`; \
	    sed -e "s|S3_AK|$$MINIO_ADMIN_AK|" \
		-e "s|S3_SK|$$MINIO_ADMIN_SK|" \
		-e "s|NAMESPACE_SED|$(NAMESPACE)|" \
		minio-secret.yaml \
		| kubectl apply -n $(NAMESPACE) -f-; \
	fi; \
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" minio-statefulset.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
	kubectl apply -n $(NAMESPACE) -f minio-service.yaml
	while ! kubectl get pods -n $(NAMESPACE) \
		| grep 'minio-[0-9].*Running' >/dev/null; \
	    do \
		echo Waiting for MinIO to start; \
		sleep 10; \
	    done
else
grafana: apicheck grafana-config
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" grafana-prometheus-configmap.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
	kubectl apply -n $(NAMESPACE) -f grafana-deployment.yaml
	kubectl apply -n $(NAMESPACE) -f grafana-service.yaml
	sed "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" grafana-ingress.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
endif

node-exporter: apicheck
	kubectl apply -n $(NAMESPACE) -f node-exporter-serviceaccount.yaml
	kubectl apply -f node-exporter-podsecuritypolicy.yaml
	kubectl apply -f node-exporter-clusterrole.yaml
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" node-exporter-clusterrolebinding.yaml \
	    | kubectl apply -f-
	kubectl apply -n $(NAMESPACE) -f node-exporter-daemonset.yaml
	kubectl apply -n $(NAMESPACE) -f node-exporter-service.yaml

kube-state-metrics: apicheck
	kubectl apply -n $(NAMESPACE) -f kube-state-metrics-serviceaccount.yaml
	kubectl apply -f kube-state-metrics-clusterrole.yaml
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" kube-state-metrics-clusterrolebinding.yaml \
	    | kubectl apply -f-
	API_MINOR=`kubectl version | awk '/Server/' | sed 's|.*Minor:"\([0-9]*\)".*|\1|'`; \
	if test "$$API_MINOR" -lt 16; then \
	    KSM_VERSION=v1.8.0; \
	elif test "$$API_MINOR" -lt 17; then \
	    KSM_VERSION=v1.9.7; \
	elif test "$$API_MINOR" -ge 0; then \
	    KSM_VERSION=v2.0.0-beta; \
	else \
	    echo FATAL: failed querying API for cluster version; \
	    exit 1; \
	fi; \
	sed "s|KSM_TAG|$$KSM_VERSION|" kube-state-metrics-deployment.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
	kubectl apply -n $(NAMESPACE) -f kube-state-metrics-service.yaml

prometheus-config:
	find prometheus-rules.d/ -type f -name '*.yaml' \
	    | cut -d/ -f2 \
	    | while read file; \
	    do \
		cmname=`echo "$$file" | sed 's|\.yaml\$$||'`; \
		kubectl create cm prometheus-rule-$$cmname \
		    --dry-run=client -o yaml \
		    --from-file=$$file=./prometheus-rules.d/$$file \
		    | kubectl apply -n $(NAMESPACE) -f-; \
	    done
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" prometheus-configmap.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-

ifeq ($(DO_THANOS),yes)
prometheus: thanos prometheus-config
	kubectl apply -n $(NAMESPACE) -f prometheus-serviceaccount.yaml
	kubectl apply -f prometheus-clusterrole.yaml
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" prometheus-clusterrolebinding.yaml \
	    | kubectl apply -f-
	kubectl apply -f prometheus-clusterrole.yaml
	if test -z "$$SC"; then \
	    echo WARNING: Did not find StorageClass: assuming ephemeral deployment; \
	    PFILE=prometheus-thanos-statefulset-volatile.yaml; \
	else \
	    PFILE=prometheus-thanos-statefulset.yaml; \
	fi; \
	kubectl apply -n $(NAMESPACE) -f $$PFILE
	kubectl apply -n $(NAMESPACE) -f prometheus-service.yaml
	kubectl apply -n $(NAMESPACE) -f prometheus-thanos-service.yaml
	sed "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" prometheus-ingress.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-

thanos-bucket: minio
	kubectl logs -n $(NAMESPACE) job/minio-init-job -f
	kubectl apply -n $(NAMESPACE) -f minio-makebucket-configmap.yaml
	if ! kubectl get secret -n $(NAMESPACE) minio-thanos-accesskey >/dev/null 2>&1; then \
	    MINIO_THANOS_AK=`tr -d -c a-z0-9 </dev/urandom 2>/dev/null | head -c 19`; \
	    MINIO_THANOS_SK=`tr -d -c a-z0-9 </dev/urandom 2>/dev/null | head -c 41`; \
	    sed -e "s|S3_AK|$$MINIO_THANOS_AK|" \
		-e "s|S3_SK|$$MINIO_THANOS_SK|" \
		-e "s|NAMESPACE_SED|$(NAMESPACE)|" \
		minio-thanos-secret.yaml \
		| kubectl apply -n $(NAMESPACE) -f-; \
	fi; \
	kubectl apply -n $(NAMESPACE) -f minio-init-job.yaml
	ACCESS_KEY=`kubectl get -o yaml -n $(NAMESPACE) secret minio-thanos-accesskey | awk '/^  access-key:/{print $$2}' | base64 --decode`; \
	SECRET_KEY=`kubectl get -o yaml -n $(NAMESPACE) secret minio-thanos-accesskey | awk '/^  secret-key:/{print $$2}' | base64 --decode`; \
	sed -e "s|ACCESSKEY_SED|$$ACCESS_KEY|" \
	    -e "s|NAMESPACE_SED|$(NAMESPACE)|" \
	    -e "s|SECRETKEY_SED|$$SECRET_KEY|" \
	    thanos-store-secret.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
	kubectl apply -n $(NAMESPACE) thanos-config-configmap.yaml
	while ! kubectl get pods -n $(NAMESPACE) 2>&1 \
		| grep 'minio-makebucket-thanos.*Running' >/dev/null; \
	    do \
		echo Waiting for MinIO init job to start; \
		sleep 10; \
	    done
	kubectl logs -n $(NAMESPACE) job/minio-makebucket-thanos -f

thanos-compact: apicheck
	kubectl apply -n $(NAMESPACE) thanos-compact-statefulset.yaml

thanos-query: apicheck
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" thanos-query-deployment.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
	kubectl apply -n $(NAMESPACE) thanos-query-service.yaml
	sed "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" thanos-query-ingress.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-

thanos-queryfrontend: apicheck
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" thanos-queryfrontend-deployment.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
	kubectl apply -n $(NAMESPACE) thanos-queryfrontend-service.yaml
	sed "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" thanos-queryfrontend-ingress.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-

thanos-store: apicheck
	kubectl apply -n $(NAMESPACE) thanos-store-statefulset.yaml
	kubectl apply -n $(NAMESPACE) thanos-store-service.yaml
	kubectl apply -n $(NAMESPACE) thanos-store-exporter-service.yaml

thanos: thanos-bucket thanos-store thanos-query thanos-queryfrontend thanos-compact

else
prometheus: apicheck prometheus-config
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" prometheus-configmap.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
	kubectl apply -n $(NAMESPACE) -f prometheus-serviceaccount.yaml
	kubectl apply -f prometheus-clusterrole.yaml
	sed "s|NAMESPACE_SED|$(NAMESPACE)|" prometheus-clusterrolebinding.yaml \
	    | kubectl apply -f-
	kubectl apply -f prometheus-clusterrole.yaml
	SC=`kubectl get sc 2>/dev/null | awk 'NR>1{print $$1;exit;}'`; \
	if test -z "$$SC"; then \
	    echo WARNING: Did not find StorageClass: assuming ephemeral deployment; \
	    PFILE=prometheus-statefulset-volatile.yaml; \
	else \
	    PFILE=prometheus-statefulset.yaml; \
	fi; \
	kubectl apply -n $(NAMESPACE) -f $$PFILE
	kubectl apply -n $(NAMESPACE) -f prometheus-service.yaml
	sed "s|ROOT_DOMAIN|$(ROOT_DOMAIN)|" prometheus-ingress.yaml \
	    | kubectl apply -n $(NAMESPACE) -f-
endif

install: node-exporter kube-state-metrics alertmanager prometheus grafana
