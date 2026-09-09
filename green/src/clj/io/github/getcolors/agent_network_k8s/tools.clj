(ns io.github.getcolors.agent-network-k8s.tools
  (:require [cheshire.core :as json]
            [io.github.getcolors.compute-managed :as managed]
            [clojure.java.io :as io]
            [clojure.string :as str]
            [green.cli :as green-cli]
            [green.process :as process]
            [green.scaffold :as sc]
            [green.tofu :as tofu]
            [green.workflow :as wf]
            [io.github.getcolors.agent-network-k8s.validate :as validate]))

(def infrastructure-tool "agent-network-k8s-infrastructure")
(def registry-tool "agent-network-k8s-registry")
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
    (when-not (.renameTo tmp f)
      (throw (ex-info (str "could not atomically install " path) {:path path})))))

(defn sh-quote
  "Single-quote a value for a sourced shell file: a generated credential is
  data, never syntax."
  [s]
  (str "'" (str/replace (str s) "'" "'\\''") "'"))

;; ---------------------------------------------------------------- compute

(defn infrastructure-data [opts]
  (assoc opts
         :compute-name (validate/compute-name opts)
         :registry-name (validate/registry-name opts)))

(defn output-params [result]
  (some-> (get-in result [:tofu/outputs :params]) clojure.walk/keywordize-keys))

(defn output-value [result k]
  (get-in result [:tofu/outputs k]))

(defn persist-cluster-access!
  "Write the kubeconfig and the registry credentials where the converge
  scripts read them: private files under the profile directory, never in a
  rendered template, never in a golden."
  [opts result]
  (let [urn (str (output-value result :registry-urn))
        user (str (output-value result :registry-username))
        pass (str (output-value result :registry-password))]
    (when (and (not-empty urn) (not-empty user))
      (write-private! (registry-env-path opts)
                      (str "REGISTRY_URN=" (sh-quote urn) "\n"
                           "REGISTRY_USER=" (sh-quote user) "\n"
                           "REGISTRY_PASS=" (sh-quote pass) "\n")))))

(defn compute-request [opts]
  {:legacy_state_keys [(str (:profile opts) "/agent-network-k8s-infrastructure.tfstate")]})

(defn- compute-result [opts result]
  (if-not (contains? #{"planned" "ready" "present" "destroyed"} (:status result))
    (assoc opts :green/exit 1 :green/err (if (seq (:errors result)) (str/join "\n" (:errors result)) "managed compute lifecycle refused"))
    (do
      (when (and (contains? #{"ready" "present"} (:status result)) (:params result))
        (doseq [[key file] [[:pod_cidr "cluster-subnet"] [:service_cidr "service-subnet"]]]
          (when-let [value (get-in result [:params key])]
            (write-private! (str (io/file (state-dir opts) file)) value))))
      (cond-> (merge opts (:params result) {:green/exit 0 :colors-compute/managed (:params result)})
        (:kubeconfig_path result) (assoc :colors-compute/kubeconfig-path (:kubeconfig_path result))))))

(defn- compute-json [value indent]
  (let [padding #(apply str (repeat % " "))]
    (cond
      (map? value) (if (empty? value) "{}"
                      (str "{\n" (str/join ",\n" (for [[key item] (sort-by key value)]
                                                       (str (padding (+ indent 2)) (json/generate-string key) ": " (compute-json item (+ indent 2)))))
                           "\n" (padding indent) "}"))
      (sequential? value) (if (empty? value) "[]"
                              (str "[\n" (str/join ",\n" (map #(str (padding (+ indent 2)) (compute-json % (+ indent 2))) value)) "\n" (padding indent) "]"))
      :else (json/generate-string value))))

(defn infrastructure-step [opts]
  (try
    (let [planning (or (= :build (:green/event opts)) (:green/dry-run opts))
          result (if planning (managed/plan-managed-kubernetes opts (compute-request opts))
                     (managed/managed-kubernetes opts (compute-request opts)))]
      (when planning
        (doseq [[file document] (:documents result)]
          (let [target (io/file (profile-dir opts) "compute" "managed-kubernetes" (name file))]
            (io/make-parents target)
            (spit target (str (compute-json document 0) "\n")))))
      (compute-result opts result))
    (catch Exception _ (assoc opts :green/exit 1 :green/err "managed compute lifecycle refused"))))

(defn load-infrastructure-step [opts]
  (if (:green/dry-run opts)
    (infrastructure-step opts)
    (let [result (managed/read-managed-kubernetes opts (compute-request opts))]
      (if (= "destroyed" (:status result))
        (assoc opts :green/exit 0 :agent-network-k8s/already-destroyed true)
        (compute-result opts result)))))

(defn registry-step [opts]
  (let [dir (tool-dir opts registry-tool)
        data (infrastructure-data opts)
        specs [(spec (template "registry" "main.tf") (str dir "/main.tf") data)]
        preflight-error nil]
    (if preflight-error
      (assoc opts :green/exit 1 :green/err preflight-error)
      (let [result (tofu/tofu-with-spec opts specs {:dir dir :env (credential-env opts :provider-registry)})]
        (when (and (not (wf/failed? result)) (= :create (:green/event opts)) (not (:green/dry-run opts)))
          (persist-cluster-access! opts result))
        result))))

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
         :compute-load-balancer-annotations (json/generate-string (into (sorted-map) (:load_balancer_annotations (managed/managed-application-settings opts (:colors-compute/managed opts)))))
         :compute-pod-cidr (:pod_cidr (managed/managed-application-settings opts (:colors-compute/managed opts)))
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
    (into (mapv (fn [[subpath tdir]]
                  (spec (template tdir (.getName (io/file subpath))) (str dir "/" subpath) data))
                deploy-files)
          (concat (map (fn [[name content]] (raw-spec (str dir "/" name) content))
                       (managed/managed-application-artifacts opts ["managed-cleanup.sh"]))
                  [(raw-spec (str dir "/desired.json") (desired-json data))
                   (raw-spec (str dir "/inventory.json") (inventory data))]))))

(defn kubeconfig-error
  "Why the profile's kubeconfig must not be used, or nil: a bearer credential
  that is a symlink, not a regular file, group/world-readable, or owned by
  someone else is not this deployment's to wield. Called on every execution
  path that wields it — workflow scripts, status, and the kubectl verb."
  [opts]
  (let [f (io/file (kubeconfig-path opts))
        p (.toPath f)
        nofollow (into-array java.nio.file.LinkOption
                             [java.nio.file.LinkOption/NOFOLLOW_LINKS])]
    (when (.exists f)
      (or (when (java.nio.file.Files/isSymbolicLink p)
            (str "kubeconfig at " f " is a symlink"))
          (when-not (java.nio.file.Files/isRegularFile p nofollow)
            (str "kubeconfig at " f " is not a regular file"))
          (let [owner (str (java.nio.file.Files/getOwner p nofollow))
                me (System/getProperty "user.name")]
            (when-not (= owner me)
              (str "kubeconfig at " f " is owned by " owner ", not " me)))
          (let [perms (java.nio.file.Files/getPosixFilePermissions p nofollow)]
            (when (some #(contains? perms %)
                        [java.nio.file.attribute.PosixFilePermission/GROUP_READ
                         java.nio.file.attribute.PosixFilePermission/GROUP_WRITE
                         java.nio.file.attribute.PosixFilePermission/OTHERS_READ
                         java.nio.file.attribute.PosixFilePermission/OTHERS_WRITE])
              (str "kubeconfig at " f " is not owner-only; chmod 600 it")))))))

(defn run-script
  "Run one rendered deploy script with the caller's terminal attached. The
  scripts read run facts from their environment (paths only — secrets stay in
  the inherited COLORS_PAR_* variables and private state files, never argv)."
  [opts script & args]
  (when-let [err (kubeconfig-error opts)]
    (throw (ex-info err {:script script})))
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
  "Withdraw application resources before destroying managed compute."
  [opts]
  (let [rendered (sc/scaffold (assoc opts :green/event :create) (deploy-specs opts))
        rendered (assoc rendered :green/event :delete)]
    (if (.exists (io/file (kubeconfig-path opts)))
      (run-script rendered "teardown.sh")
      (assoc rendered :green/exit 1 :green/err "managed cluster access unavailable"))))

(defn cleanup-step
  "Remove the local per-profile access material after the infrastructure is
  gone: the kubeconfig is a dead bearer credential, the state files describe
  a cluster that no longer exists."
  [opts]
  (when (= :delete (:green/event opts))
    (doseq [f [(kubeconfig-path opts)]]
      (let [file (io/file f)] (when (.exists file) (io/delete-file file))))
    (doseq [dir [(io/file (state-dir opts))
                 (io/file (profile-dir opts) "proofs")]]
      (when (.exists dir)
        (doseq [f (reverse (file-seq dir))] (io/delete-file f true)))))
  (assoc opts :green/exit 0))

;; ------------------------------------------------------------- kubectl verb

(defn status-main
  "The launcher's status verb: render nothing, run the already-rendered
  status script against the live cluster. Returns the exit code."
  [state-file]
  (let [opts (assoc (green-cli/read-state state-file (slurp state-file)) :green/state-file state-file)
        dir (tool-dir opts deploy-tool)
        script (io/file dir "status.sh")]
    (cond
      (not (.exists script))
      (do (binding [*out* *err*]
            (println (str "no rendered status script at " script "; run build first")))
          2)

      (kubeconfig-error opts)
      (do (binding [*out* *err*] (println (kubeconfig-error opts))) 2)

      :else
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
    (cond
      (not (.exists (io/file kc)))
      (do (binding [*out* *err*]
            (println (str "no kubeconfig at " kc "; run create first")))
          2)

      (kubeconfig-error opts)
      (do (binding [*out* *err*] (println (kubeconfig-error opts))) 2)

      :else
      (:exit (process/run-inherit (into ["env" (str "KUBECONFIG=" kc) "kubectl"] args))))))
