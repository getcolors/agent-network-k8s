(ns io.github.getcolors.agent-network-k8s.workflow
  (:require [green.cli :as green-cli]
            [green.dry-run :as dry-run]
            [green.lifecycle :as lifecycle]
            [green.progress :as progress]
            [green.tofu :as tofu]
            [green.workflow :as wf]
            [io.github.getcolors.agent-network-k8s.tools :as tools]
            [io.github.getcolors.agent-network-k8s.validate :as validate]))

(def defaults {:provider-compute "vultr" :provider-dns "cloudflare"
               :provider-backend "local" :compute-prevent-destroy true
               :workdir ".colors"})

(defn start-step
  ([opts] (start-step opts (System/getenv)))
  ([opts env]
   (lifecycle/preflight
    opts {:defaults defaults :overlay green-cli/read-pars
          :validators
          [(fn [_ env _] (validate/env-errors env))
           (fn [opts _ _] (validate/state-errors opts))
           (fn [opts _ {:keys [event real?]}]
             (when (and real? (contains? #{:create :delete} event))
               (validate/secret-errors opts event)))
           (fn [opts _ {:keys [event real?]}]
             (when (and real? (= :delete event) (:compute-prevent-destroy opts))
               [(str "compute destruction is protected; set "
                     (green-cli/par-name :compute-prevent-destroy) "=false to delete")]))]}
    env)))

(defn wire-fn [step run-opts]
  (if (= :delete (:green/event run-opts))
    ;; In-cluster teardown first: the CSI volumes and the CCM-created load
    ;; balancer are Kubernetes-managed and invisible to the infrastructure
    ;; state, so destroying the cluster before removing them would orphan
    ;; them in the account. Local access material goes last — the kubeconfig
    ;; is needed by the teardown and dead only after the destroy.
    (case step
      :agent-network-k8s/start [start-step :agent-network-k8s/teardown]
      :agent-network-k8s/teardown [tools/teardown-step :agent-network-k8s/dns]
      :agent-network-k8s/dns [tools/dns-step :agent-network-k8s/infrastructure]
      :agent-network-k8s/infrastructure [tools/infrastructure-step :agent-network-k8s/cleanup]
      :agent-network-k8s/cleanup [tools/cleanup-step])
    ;; Create: the cluster first; then the workloads (the edge and the proxy
    ;; are applied but deliberately not awaited — they mount a TLS Secret
    ;; that does not exist yet); DNS once the load balancer has an address;
    ;; the certificate once DNS can answer DNS-01; then the control plane,
    ;; the two-pod application, and the gates.
    (case step
      :agent-network-k8s/start [start-step :agent-network-k8s/infrastructure]
      :agent-network-k8s/infrastructure [tools/infrastructure-step :agent-network-k8s/deploy]
      :agent-network-k8s/deploy [tools/deploy-step :agent-network-k8s/dns]
      :agent-network-k8s/dns [tools/dns-step :agent-network-k8s/certificate]
      :agent-network-k8s/certificate [tools/certificate-step :agent-network-k8s/bootstrap]
      :agent-network-k8s/bootstrap [tools/bootstrap-step :agent-network-k8s/agent]
      :agent-network-k8s/agent [tools/agent-step :agent-network-k8s/acceptance]
      :agent-network-k8s/acceptance [tools/acceptance-step])))

(defn backend-advice [tool]
  (tofu/conventional-backend-advice
   {:dir-fn #(tools/tool-dir % tool)
    :key-fn #(str (:profile %) "/" tool ".tfstate")}))

(def side-effecting
  [:agent-network-k8s/infrastructure :agent-network-k8s/deploy
   :agent-network-k8s/dns :agent-network-k8s/certificate
   :agent-network-k8s/bootstrap :agent-network-k8s/agent
   :agent-network-k8s/acceptance :agent-network-k8s/teardown
   :agent-network-k8s/cleanup])

(def workflow
  (-> (wf/workflow {:start :agent-network-k8s/start :wire-fn wire-fn})
      (wf/advice-add :agent-network-k8s/infrastructure :before ::backend
                     (backend-advice tools/infrastructure-tool))
      (wf/advice-add :agent-network-k8s/dns :before ::backend (backend-advice tools/dns-tool))
      progress/advise
      (dry-run/advise side-effecting)))
