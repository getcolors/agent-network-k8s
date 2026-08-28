(ns io.github.getcolors.agent-network-k8s.tools
  (:require [cheshire.core :as json]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [green.cli :as green-cli]
            [green.process :as process]
            [green.scaffold :as sc]
            [green.tofu :as tofu]
            [green.workflow :as wf]
            [io.github.getcolors.agent-network-k8s.validate :as validate]))

(def infrastructure-tool "agent-network-k8s-infrastructure")
(def dns-tool "agent-network-k8s-dns")
(def deploy-tool "agent-network-k8s-deploy")
(def root "io.github.getcolors.agent-network-k8s.tools")
(def template-opts sc/preserve-jinja-delimiters)

(defn tool-dir [opts tool] (green-cli/stage-dir opts tool {:default-profile "agent-network-k8s"}))
(defn template [path file] (keyword (str root "." path) file))
(defn spec [source target data] {:template source :target target :data data :opts template-opts})
(defn raw-spec [target content] (sc/content-spec target content))

(defn profile-dir
  "The per-profile directory the stage directories live in. The kubeconfig,
  the launcher-side state files, and lego's account state all live here —
  generated, gitignored, and removed by delete."
  [opts]
  (str (.getParentFile (io/file (tool-dir opts deploy-tool)))))

(defn kubeconfig-path [opts] (str (io/file (profile-dir opts) "kubeconfig")))
(defn state-dir [opts] (str (io/file (profile-dir opts) "state")))
(defn lego-dir [opts] (str (io/file (profile-dir opts) "lego")))
(defn registry-env-path [opts] (str (io/file (state-dir opts) "registry.env")))

(defn cidrs [opts k]
  (let [v (get opts k) xs (if (sequential? v) v (str/split (str v) #"[,\s]+"))]
    (->> xs (map (comp str/trim str)) (remove str/blank?) vec)))

(defn credential-env [opts & slots]
  (not-empty
   (into {} (keep (fn [[k env-var]]
                    (when-let [v (not-empty (str (get opts k)))] [env-var v])))
         (apply merge (map #(validate/tofu-env opts %) (conj (vec slots) :provider-backend))))))
(defn backend-credential-env [opts] (credential-env opts))

(defn fallback-params [opts]
  {:lb-ip "192.0.2.10" :name (validate/compute-name opts)})

;; ------------------------------------------------------------ file helpers

(defn write-private!
  "Write `content` to `path` atomically with owner-only permissions: temp file
  beside the target, chmod, rename. A crash never leaves a half-written or
  world-readable credential."
  [path content]
  (let [f (io/file path) tmp (io/file (str path ".tmp"))]
    (io/make-parents f)
    (spit tmp content)
    (let [p (.toPath tmp)]
      (java.nio.file.Files/setPosixFilePermissions
       p (java.util.Set/of java.nio.file.attribute.PosixFilePermission/OWNER_READ
                           java.nio.file.attribute.PosixFilePermission/OWNER_WRITE)))
    (.renameTo tmp f)))

;; ---------------------------------------------------------------- compute

(defn infrastructure-data [opts]
  (assoc opts
         :compute-name (validate/compute-name opts)
         :registry-name (validate/registry-name opts)))

(defn vke-version-error
  "Why the pinned VKE version cannot be created, or nil. VKE retires old
  minors, so the pin is checked against the live supported list while failing
  is still free — a tofu apply that dies half-way leaves a cluster to clean
  up, this check leaves nothing."
  [opts]
  (let [{:keys [exit out]} (process/run
                            ["curl" "-fsS" "-H" (str "Authorization: Bearer " (:vultr-api-key opts))
                             "https://api.vultr.com/v2/kubernetes/versions"]
                            {})]
    (when (zero? exit)
      (let [versions (get (json/parse-string out) "versions")]
        (when (and (seq versions)
                   (not (some #{(str (:vultr-vke-version opts))} versions)))
          (str "vultr-vke-version " (:vultr-vke-version opts)
               " is not offered by VKE; currently supported: "
               (str/join ", " versions)))))))

(defn output-params [result]
  (some-> (get-in result [:tofu/outputs :params]) clojure.walk/keywordize-keys))

(defn output-value [result k]
  (get-in result [:tofu/outputs k]))

(defn persist-cluster-access!
  "Write the kubeconfig and the registry credentials where the converge
  scripts read them: private files under the profile directory, never in a
  rendered template, never in a golden."
  [opts result]
  (when-let [kc (not-empty (str (output-value result :kubeconfig-b64)))]
    (write-private! (kubeconfig-path opts)
                    (String. (.decode (java.util.Base64/getDecoder) ^String kc))))
  (let [urn (str (output-value result :registry-urn))
        user (str (output-value result :registry-username))
        pass (str (output-value result :registry-password))]
    (when (and (not-empty urn) (not-empty user))
      (write-private! (registry-env-path opts)
                      (str "REGISTRY_URN=" urn "\n"
                           "REGISTRY_USER=" user "\n"
                           "REGISTRY_PASS=" pass "\n")))))

(defn infrastructure-step [opts]
  (let [dir (tool-dir opts infrastructure-tool)
        specs [(spec (template "infrastructure" "main.tf") (str dir "/main.tf")
                     (infrastructure-data opts))]
        version-err (when (and (= :create (:green/event opts))
                               (not (:green/dry-run opts)))
                      (vke-version-error opts))]
    (if version-err
      (assoc opts :green/exit 1 :green/err version-err)
      (let [result (tofu/tofu-with-spec opts specs
                                        {:dir dir :env (credential-env opts :provider-compute)})]
        (cond
          (wf/failed? result) result
          (= :build (:green/event opts)) (merge result (fallback-params opts))
          (= :delete (:green/event opts)) result
          :else (do (persist-cluster-access! opts result)
                    (merge result (fallback-params opts) (output-params result))))))))

;; -------------------------------------------------------------------- dns

(defn dns-json
  "The base record and its wildcard, both unproxied: Cloudflare's proxy would
  terminate TLS in front of an edge whose certificate this deployment issues
  itself, and the wildcard is contract, not convenience — the agent-network
  endpoint is a label management mints beneath the base domain at bootstrap,
  and nothing knows that label before it exists."
  [opts]
  (tofu/constructs-json
   [(tofu/construct :resource :cloudflare_dns_record :agent_network_k8s
                    {:zone_id "${data.cloudflare_zone.zone.id}"
                     :name (:agent-network-host opts) :content (:lb-ip opts) :type "A"
                     :proxied false :ttl 60})
    (tofu/construct :resource :cloudflare_dns_record :agent_network_k8s_wildcard
                    {:zone_id "${data.cloudflare_zone.zone.id}"
                     :name (str "*." (:agent-network-host opts)) :content (:lb-ip opts)
                     :type "A" :proxied false :ttl 60})]))

(defn dns-step [opts]
  (let [dir (tool-dir opts dns-tool)
        data (assoc opts
                    :lb-ip (or (:lb-ip opts) (:lb-ip (fallback-params opts)))
                    :agent-network-zone (validate/zone opts))
        specs [(spec (template "dns" "main.tf") (str dir "/main.tf") data)
               (raw-spec (str dir "/record.tf.json") (dns-json data))]]
    (tofu/tofu-with-spec opts specs {:dir dir :env (credential-env opts :provider-dns)})))

;; ------------------------------------------------------------------ deploy

(defn inventory
  "Non-secret run facts the scripts read as JSON — the k8s analog of the
  parent's Ansible inventory."
  [opts]
  (json/generate-string
   {:host (:agent-network-host opts)
    :profile (:profile opts)
    :compute_name (validate/compute-name opts)}
   {:pretty true}))

(defn desired-json
  "The control plane's desired state, one JSON document the bootstrap
  reconciles against. Everything in it is non-secret — the Anthropic key
  reaches the bootstrap as an environment variable resolved at run time and
  never lands in a rendered file."
  [opts]
  (json/generate-string
   {:host (:agent-network-host opts)
    :admin_email (:agent-network-admin-email opts)
    :admin_name (:agent-network-admin-name opts)
    :provider
    ;; The catalog id, from GET /api/agent-network/catalog/providers on the
    ;; pinned release — "anthropic" alone is a 422.
    {:provider_id "anthropic_api"
     :name "Anthropic"
     :upstream_url "https://api.anthropic.com"
     :models (for [m (validate/provider-models opts)]
               (cond-> {:id (str (:id m))
                        :input_per_1k (:input-per-1k m)
                        :output_per_1k (:output-per-1k m)}
                 (some? (:cache-read-per-1k m))
                 (assoc :cache_read_per_1k (:cache-read-per-1k m))
                 (some? (:cache-creation-per-1k m))
                 (assoc :cache_creation_per_1k (:cache-creation-per-1k m))))}
    :allowed_models (validate/allowed-models opts)
    :policy {:budget_usd_per_day (:agent-network-policy-budget-usd-per-day opts)
             :tokens_per_day (:agent-network-policy-tokens-per-day opts)}
    :global {:budget_usd_per_day (:agent-network-global-budget-usd-per-day opts)
             :tokens_per_day (:agent-network-global-tokens-per-day opts)}
    :log_retention_days (:agent-network-log-retention-days opts)}
   {:pretty true}))

(defn deploy-data
  "Template values for every deploy-stage file. Deliberately carries no
  operator secret: the Anthropic key, the Cloudflare token and the registry
  credentials reach the scripts through the process environment or private
  state files, so nothing in .colors/ or a golden ever holds one."
  [opts]
  (assoc opts
         :allowed-model (validate/allowed-model opts)
         :denied-claimed-model (validate/denied-claimed-model opts)
         ;; The escaped base domain for Traefik's HostSNIRegexp: only
         ;; endpoint subdomains ride the TCP passthrough, never the bare
         ;; base name (TCP routers outrank HTTP routers in Traefik).
         :host-regex (str/replace (str (:agent-network-host opts)) "." "\\.")))

(def deploy-files
  "Rendered scripts and manifests, one entry per file: [subpath template-dir]."
  [["converge.sh" "deploy"]
   ["certificate.sh" "deploy"]
   ["bootstrap.sh" "deploy"]
   ["agent.sh" "deploy"]
   ["smoke.sh" "deploy"]
   ["disrupt.sh" "deploy"]
   ["status.sh" "deploy"]
   ["teardown.sh" "deploy"]
   ["netbird-config.yaml" "deploy"]
   ["traefik-dynamic.yaml" "deploy"]
   ["manifests/namespaces.yaml" "deploy.manifests"]
   ["manifests/traefik.yaml" "deploy.manifests"]
   ["manifests/netbird-server.yaml" "deploy.manifests"]
   ["manifests/dashboard.yaml" "deploy.manifests"]
   ["manifests/proxy.yaml" "deploy.manifests"]
   ["manifests/netbird-client.yaml" "deploy.manifests"]
   ["manifests/agent-primary.yaml" "deploy.manifests"]
   ["manifests/agent-fallback.yaml" "deploy.manifests"]
   ["manifests/networkpolicies.yaml" "deploy.manifests"]
   ["manifests/build-job.yaml" "deploy.manifests"]
   ["agent-image/Dockerfile" "deploy.agent-image"]
   ["agent-image/package.json" "deploy.agent-image"]
   ["agent-image/package-lock.json" "deploy.agent-image"]
   ["agent-image/bridge-entry.sh" "deploy.agent-image"]
   ["agent-image/privoxy.config" "deploy.agent-image"]
   ["socks-entry.sh" "deploy"]])

(defn deploy-specs [opts]
  (let [dir (tool-dir opts deploy-tool) data (deploy-data opts)]
    (conj
     (mapv (fn [[subpath tdir]]
             (spec (template tdir (.getName (io/file subpath))) (str dir "/" subpath) data))
           deploy-files)
     (raw-spec (str dir "/desired.json") (desired-json data))
     (raw-spec (str dir "/inventory.json") (inventory data)))))

(defn run-script
  "Run one rendered deploy script with the caller's terminal attached. The
  scripts read run facts from their environment (paths only — secrets stay in
  the inherited COLORS_PAR_* variables and private state files, never argv)."
  [opts script & args]
  (let [dir (tool-dir opts deploy-tool)
        argv (-> ["env"
                  (str "KUBECONFIG=" (kubeconfig-path opts))
                  (str "STATE_DIR=" (state-dir opts))
                  (str "DEPLOY_DIR=" dir)
                  (str "LEGO_DIR=" (lego-dir opts))
                  "bash" (str dir "/" script)]
                 (into args))
        {:keys [exit err]} (process/run-inherit argv)]
    (if (zero? (or exit 1))
      (assoc opts :green/exit 0)
      (assoc opts :green/exit (or exit 1)
             :green/err (or err (str script " exited " exit))))))

(defn script-step
  "Scaffold the deploy tree, then on a real :create run `script`. :build
  renders and stops; :delete is handled by `teardown-step`, not here."
  [opts script & args]
  (let [rendered (sc/scaffold (assoc opts :green/event :create) (deploy-specs opts))
        rendered (assoc rendered :green/event (:green/event opts))]
    (if (not= :create (:green/event opts))
      (assoc rendered :green/exit 0)
      (apply run-script rendered script args))))

(defn read-state-file [opts name]
  (let [f (io/file (state-dir opts) name)]
    (when (.exists f) (str/trim (slurp f)))))

(defn deploy-step
  "Phase one of convergence: namespaces, create-once secrets, the in-cluster
  agent-image build, the gateway workloads, the proxy token, and the load
  balancer. Ends knowing the LB address, which the dns stage publishes."
  [opts]
  (let [result (script-step opts "converge.sh")]
    (cond
      (wf/failed? result) result
      (not= :create (:green/event opts)) result
      :else (if-let [ip (read-state-file opts "lb-ip")]
              (assoc result :lb-ip ip)
              (assoc result :green/exit 1
                     :green/err "converge recorded no load-balancer address")))))

(defn certificate-step
  "Issue or renew the wildcard pair (both SANs: the base name and *.base —
  a wildcard alone does not cover the bare base name) launcher-side via
  DNS-01, apply it as the TLS Secret, then wait for the edge and the proxy,
  whose readiness was deliberately not awaited before the Secret existed."
  [opts]
  (script-step opts "certificate.sh"))

(defn bootstrap-step [opts] (script-step opts "bootstrap.sh"))
(defn agent-step [opts] (script-step opts "agent.sh"))

(defn acceptance-step [opts]
  (let [result (script-step opts "smoke.sh")]
    (if (or (wf/failed? result) (not= :create (:green/event opts)))
      result
      (assoc result :agent-network-k8s/acceptance
             {:endpoint (read-state-file opts "endpoint")
              :isolation "probed"
              :tunnel-only "confirmed"}))))

(defn teardown-step
  "Ordered in-cluster teardown before the infrastructure destroy: workloads,
  PVCs (waiting for the CSI volumes to leave the account), then the LB
  Service (waiting for the LB to leave the account). Skips cleanly when the
  cluster is already gone or was never created."
  [opts]
  (let [rendered (sc/scaffold (assoc opts :green/event :create) (deploy-specs opts))
        rendered (assoc rendered :green/event :delete)]
    (if (.exists (io/file (kubeconfig-path opts)))
      (let [r (run-script rendered "teardown.sh")]
        ;; A cluster that stopped answering must not block the destroy that
        ;; removes it: teardown is best-effort, the tofu destroy is the
        ;; authority.
        (assoc r :green/exit 0))
      (assoc rendered :green/exit 0))))

(defn cleanup-step
  "Remove the local per-profile access material after the infrastructure is
  gone: the kubeconfig is a dead bearer credential, the state files describe
  a cluster that no longer exists."
  [opts]
  (when (= :delete (:green/event opts))
    (doseq [f [(kubeconfig-path opts)]]
      (let [file (io/file f)] (when (.exists file) (io/delete-file file))))
    (let [state (io/file (state-dir opts))]
      (when (.exists state)
        (doseq [f (reverse (file-seq state))] (io/delete-file f true)))))
  (assoc opts :green/exit 0))

;; ------------------------------------------------------------- kubectl verb

(defn status-main
  "The launcher's status verb: render nothing, run the already-rendered
  status script against the live cluster. Returns the exit code."
  [state-file]
  (let [opts (assoc (green-cli/read-state state-file (slurp state-file)) :green/state-file state-file)
        dir (tool-dir opts deploy-tool)
        script (io/file dir "status.sh")]
    (if-not (.exists script)
      (do (binding [*out* *err*]
            (println (str "no rendered status script at " script "; run build first")))
          2)
      (:exit (process/run-inherit
              ["env" (str "KUBECONFIG=" (kubeconfig-path opts))
               (str "STATE_DIR=" (state-dir opts))
               (str "DEPLOY_DIR=" dir)
               "bash" (str script)])))))

(defn kubectl-main
  "The launcher's kubectl passthrough: run kubectl against this deployment's
  cluster with the profile's kubeconfig. Returns the exit code."
  [state-file args]
  (let [opts (assoc (green-cli/read-state state-file (slurp state-file)) :green/state-file state-file)
        kc (kubeconfig-path opts)]
    (if-not (.exists (io/file kc))
      (do (binding [*out* *err*]
            (println (str "no kubeconfig at " kc "; run create first")))
          2)
      (:exit (process/run-inherit (into ["env" (str "KUBECONFIG=" kc) "kubectl"] args))))))
