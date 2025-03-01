package main_test

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/exec"
	"path"
	"strconv"

	. "telemetry_receiver"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"
	"github.com/onsi/gomega/gexec"
)

var (
	validToken        = "1234"
	validTokenContent = "Bearer " + validToken
	messageLimit      = "50"
)

var _ = Describe("Main", func() {
	var (
		session   *gexec.Session
		serverUrl string
	)

	BeforeEach(func() {
		port, err := findFreePort()
		Expect(err).NotTo(HaveOccurred())
		session = startServer(binaryPath, port, map[string]string{})
		Eventually(func() bool {
			return dialLoader(port)
		}).Should(BeTrue())
		serverUrl = fmt.Sprintf("http://127.0.0.1:%s", port)
	})

	AfterEach(func() {
		session.Kill()
		Eventually(session).Should(gexec.Exit())
	})

	Describe("Main", func() {
		Describe("/components", func() {
			It("allows retrieval of messages for user sent to /components", func() {
				resp := makeRequest(http.MethodGet, serverUrl+"/received_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{}))

				telemetryMsg := generateTelemetryMsg()
				resp = makeRequest(http.MethodPost, serverUrl+"/components", validTokenContent, telemetryMsg)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err = io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{
					{
						"create-instance":     map[string]interface{}{"cluster-size": "42", "cool-feature-enabled": "true"},
						"telemetry-source":    "my-component",
						"telemetry-timestamp": "2009-11-10T23:00:00Z",
					},
					{
						"create-instance":     map[string]interface{}{"cluster-size": "24", "cool-feature-enabled": "false"},
						"telemetry-source":    "my-component",
						"telemetry-timestamp": "2009-11-11T23:00:00Z",
					},
				}))
			})

			It("returns empty array when the only messages sent to /components were empty", func() {
				resp := makeRequest(http.MethodGet, serverUrl+"/received_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))
				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{}))

				resp = makeRequest(http.MethodPost, serverUrl+"/components", validTokenContent, []byte{})
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err = io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				Expect(string(respBody)).To(Equal("[]"))
			})

			It("appends to previous messages", func() {
				telemetryMsg := generateTelemetryMsg()
				resp := makeRequest(http.MethodPost, serverUrl+"/components", validTokenContent, telemetryMsg)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodPost, serverUrl+"/components", validTokenContent, telemetryMsg)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{
					{
						"create-instance":     map[string]interface{}{"cluster-size": "42", "cool-feature-enabled": "true"},
						"telemetry-source":    "my-component",
						"telemetry-timestamp": "2009-11-10T23:00:00Z",
					},
					{
						"create-instance":     map[string]interface{}{"cluster-size": "24", "cool-feature-enabled": "false"},
						"telemetry-source":    "my-component",
						"telemetry-timestamp": "2009-11-11T23:00:00Z",
					},
					{
						"create-instance":     map[string]interface{}{"cluster-size": "42", "cool-feature-enabled": "true"},
						"telemetry-source":    "my-component",
						"telemetry-timestamp": "2009-11-10T23:00:00Z",
					},
					{
						"create-instance":     map[string]interface{}{"cluster-size": "24", "cool-feature-enabled": "false"},
						"telemetry-source":    "my-component",
						"telemetry-timestamp": "2009-11-11T23:00:00Z",
					},
				}))
			})

			It("only returns messages sent by a specific user", func() {
				telemetryMsg := generateTelemetryMsg()
				resp := makeRequest(http.MethodPost, serverUrl+"/components", validTokenContent, telemetryMsg)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{
					{
						"create-instance":     map[string]interface{}{"cluster-size": "42", "cool-feature-enabled": "true"},
						"telemetry-source":    "my-component",
						"telemetry-timestamp": "2009-11-10T23:00:00Z",
					},
					{
						"create-instance":     map[string]interface{}{"cluster-size": "24", "cool-feature-enabled": "false"},
						"telemetry-source":    "my-component",
						"telemetry-timestamp": "2009-11-11T23:00:00Z",
					},
				}))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_messages", "Bearer second-token", nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err = io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{}))
			})

			It("users can clear previously sent messages", func() {
				telemetryMsg := generateTelemetryMsg()
				resp := makeRequest(http.MethodPost, serverUrl+"/components", validTokenContent, telemetryMsg)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodPost, serverUrl+"/clear_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{}))
			})

			It("clears a user's messages when it has reached the message limit", func() {
				limit, err := strconv.Atoi(messageLimit)
				Expect(err).NotTo(HaveOccurred())
				for i := 0; i <= limit; i++ {
					msg := []byte(fmt.Sprintf(`{"msgNum": %d}`, i))
					resp := makeRequest(http.MethodPost, serverUrl+"/components", validTokenContent, msg)
					resp.Body.Close()
					Expect(resp.StatusCode).To(Equal(http.StatusCreated))
				}
				resp := makeRequest(http.MethodGet, serverUrl+"/received_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(len(messages)).To(Equal(limit))
				Expect(messages[0]).To(Equal(map[string]interface{}{"msgNum": float64(1)}))
				Expect(messages[len(messages)-1]).To(Equal(map[string]interface{}{"msgNum": float64(50)}))
			})

			It("returns an bad request error when the json is invalid format", func() {
				resp := makeRequest(http.MethodPost, serverUrl+"/components", validTokenContent, []byte("invalid"))
				Expect(resp.StatusCode).To(Equal(http.StatusBadRequest))
			})
		})

		Describe("/collections/batch", func() {
			It("allows retrieval of data about messages sent by a user to /batch", func() {
				resp := makeRequest(http.MethodGet, serverUrl+"/received_batch_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{}))

				resp = makeBatchRequest(http.MethodPost, serverUrl, validTokenContent, true, generateTarFileContents("best-foundation-id", true))
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_batch_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err = io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{
					{
						"FoundationId": "best-foundation-id",
						"CollectedAt":  "2006-01-02T15:04:05Z07:00",
						"Dataset":      "opsmanager",
					},
				}))
			})

			It("appends to previous messages", func() {
				resp := makeBatchRequest(http.MethodPost, serverUrl, validTokenContent, true, generateTarFileContents("best-foundation-id", true))
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeBatchRequest(http.MethodPost, serverUrl, validTokenContent, true, generateTarFileContents("best-foundation-id", true))
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_batch_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{
					{
						"FoundationId": "best-foundation-id",
						"CollectedAt":  "2006-01-02T15:04:05Z07:00",
						"Dataset":      "opsmanager",
					},
					{
						"FoundationId": "best-foundation-id",
						"CollectedAt":  "2006-01-02T15:04:05Z07:00",
						"Dataset":      "opsmanager",
					},
				}))
			})

			It("only returns messages sent by a specific user", func() {
				resp := makeBatchRequest(http.MethodPost, serverUrl, validTokenContent, true, generateTarFileContents("best-foundation-id", true))
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_batch_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{
					{
						"FoundationId": "best-foundation-id",
						"CollectedAt":  "2006-01-02T15:04:05Z07:00",
						"Dataset":      "opsmanager",
					},
				}))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_batch_messages", "Bearer second-token", nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err = io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{}))
			})

			It("users can clear previously sent messages", func() {
				resp := makeBatchRequest(http.MethodPost, serverUrl, validTokenContent, true, generateTarFileContents("best-foundation-id", true))
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodPost, serverUrl+"/clear_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_batch_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{}))
			})

			It("users can send uncompressed batch messages", func() {

				resp := makeRequest(http.MethodPost, serverUrl+"/clear_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				resp = makeBatchRequest(http.MethodPost, serverUrl, validTokenContent, false, generateTarFileContents("best-foundation-id", false))
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusCreated))

				resp = makeRequest(http.MethodGet, serverUrl+"/received_batch_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(messages).To(Equal([]map[string]interface{}{
					{
						"FoundationId": "best-foundation-id",
						"CollectedAt":  "2006-01-02T15:04:05Z07:00",
						"Dataset":      "opsmanager",
					},
				}))

				resp = makeRequest(http.MethodPost, serverUrl+"/clear_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))
			})

			It("clears a user's messages when it has reached the message limit", func() {
				limit, err := strconv.Atoi(messageLimit)
				Expect(err).NotTo(HaveOccurred())
				for i := 0; i <= limit; i++ {
					resp := makeBatchRequest(http.MethodPost, serverUrl, validTokenContent, true, generateTarFileContents(strconv.Itoa(i), true))
					resp.Body.Close()
					Expect(resp.StatusCode).To(Equal(http.StatusCreated))
				}

				resp := makeRequest(http.MethodGet, serverUrl+"/received_batch_messages", validTokenContent, nil)
				defer resp.Body.Close()
				Expect(resp.StatusCode).To(Equal(http.StatusOK))

				respBody, err := io.ReadAll(resp.Body)
				Expect(err).NotTo(HaveOccurred())
				var messages []map[string]interface{}
				Expect(json.Unmarshal(respBody, &messages)).To(Succeed())
				Expect(len(messages)).To(Equal(limit))
				Expect(messages[0]["FoundationId"]).To(Equal("1"))
				Expect(messages[len(messages)-1]["FoundationId"]).To(Equal("50"))
			})

			It("returns an bad request error when the json is invalid format", func() {
				resp := makeRequest(http.MethodPost, serverUrl+"/collections/batch", validTokenContent, []byte("invalid"))
				Expect(resp.StatusCode).To(Equal(http.StatusBadRequest))
			})
		})
	})

	It("when PORT cannot be bound, it exits nonzero", func() {
		errorSession := startServer(binaryPath, "-2000", map[string]string{})
		Eventually(errorSession).Should(gexec.Exit(1))
	})

	It("when the format of the API key configuration is invalid, it exits nonzero", func() {
		errorSession := startServer(
			binaryPath, "2020", map[string]string{ApiKeysEnvVar: `totally-not-valid-json-scrub`},
		)
		Eventually(errorSession).Should(gexec.Exit(1))
		Expect(errorSession.Out).To(gbytes.Say(fmt.Sprintf(FailedUnmarshalErrorFormat, ApiKeysEnvVar)))
	})

	It("when the message limit cannot be converted to an int, it exits nonzero", func() {
		errorSession := startServer(
			binaryPath, "2020", map[string]string{MessageLimitEnvVar: "{}"},
		)
		Eventually(errorSession).Should(gexec.Exit(1))
		Expect(errorSession.Out).To(gbytes.Say(InvalidMessageLimitError))
		Expect(errorSession.Out).To(gbytes.Say(`parsing "{}"`))
	})

	DescribeTable("fails to start when required configuration is missing",
		func(missingEnvVar string) {
			env := map[string]string{
				PortEnvVar:         "8080",
				ApiKeysEnvVar:      `{}`,
				MessageLimitEnvVar: "50",
			}
			delete(env, missingEnvVar)
			errorSession := startServerWithEnv(binaryPath, env)
			Eventually(errorSession).Should(gexec.Exit(1))
			Expect(errorSession.Out).To(gbytes.Say(fmt.Sprintf(RequiredEnvVarNotSetErrorFormat, missingEnvVar)))
		},
		Entry(PortEnvVar, PortEnvVar),
		Entry(ApiKeysEnvVar, ApiKeysEnvVar),
		Entry(MessageLimitEnvVar, MessageLimitEnvVar),
	)

	DescribeTable("returns an unauthorized response when invalid token is passed",
		func(path string) {
			resp := makeRequest(http.MethodGet, serverUrl+path, "no good token", nil)
			defer resp.Body.Close()
			Expect(resp.StatusCode).To(Equal(http.StatusUnauthorized))
		},
		Entry("/components", "/components"),
		Entry("/collections/batch", "/collections/batch"),
		Entry("/received_batch_messages", "/received_batch_messages"),
		Entry("/received_messages", "/received_messages"),
		Entry("/clear_messages", "/clear_messages"),
	)
})

func startServer(loader, port string, envOverride map[string]string) *gexec.Session {
	userKeyMap := map[string][]string{
		"user-id":  {validToken},
		"user-id2": {"second-token"},
	}
	userKeyJson, err := json.Marshal(userKeyMap)
	Expect(err).NotTo(HaveOccurred())

	env := map[string]string{
		PortEnvVar:         port,
		ApiKeysEnvVar:      string(userKeyJson),
		MessageLimitEnvVar: "50",
	}
	for envVar, envVal := range envOverride {
		env[envVar] = envVal
	}

	return startServerWithEnv(loader, env)
}

func startServerWithEnv(loader string, envMap map[string]string) *gexec.Session {
	var env []string
	for k, v := range envMap {
		env = append(env, fmt.Sprintf("%s=%s", k, v))
	}
	cmd := exec.Command(loader)
	cmd.Env = env
	session, err := gexec.Start(cmd, GinkgoWriter, GinkgoWriter)
	Expect(err).NotTo(HaveOccurred())

	return session
}

func makeRequest(method, url, authHeaderContent string, data []byte) *http.Response {
	var reqBody io.Reader
	if data != nil {
		reqBody = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, url, reqBody)
	Expect(err).NotTo(HaveOccurred())
	if authHeaderContent != "" {
		req.Header.Set("Authorization", authHeaderContent)
	}
	resp, err := http.DefaultClient.Do(req)
	Expect(err).NotTo(HaveOccurred())
	return resp
}

func findFreePort() (string, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:")
	if err != nil {
		return "0", err
	}
	defer listener.Close()

	return strconv.Itoa(listener.Addr().(*net.TCPAddr).Port), nil
}

func dialLoader(port string) bool {
	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%s", port))
	if err == nil {
		_ = conn.Close()
		return true
	}
	return false
}

func generateTelemetryMsg() []byte {
	return []byte(`{
		"create-instance": {"cluster-size": "42", "cool-feature-enabled": "true"},
		"telemetry-source": "my-component",
		"telemetry-timestamp": "2009-11-10T23:00:00Z"
}{
		"create-instance": {"cluster-size": "24", "cool-feature-enabled": "false"},
		"telemetry-source": "my-component",
		"telemetry-timestamp": "2009-11-11T23:00:00Z"
}
`)
}

func makeBatchRequest(method, url, authHeaderContent string, compressed bool, data []byte) *http.Response {
	req, err := http.NewRequest(method, url+"/collections/batch", bytes.NewReader(data))
	Expect(err).NotTo(HaveOccurred())
	req.Header.Set("Content-Type", "application/tar")
	if compressed {
		req.Header.Set("Content-Encoding", "gzip")
	}
	if authHeaderContent != "" {
		req.Header.Set("Authorization", authHeaderContent)
	}
	resp, err := http.DefaultClient.Do(req)
	Expect(err).NotTo(HaveOccurred())
	return resp
}

func generateTarFileContents(foundationId string, compressed bool) []byte {
	if compressed {
		return gzippedTarForContents(
			[]byte(fmt.Sprintf(`{"FoundationId": "%s", "CollectedAt": "2006-01-02T15:04:05Z07:00"}`, foundationId)),
			path.Join("opsmanager", "metadata"),
		)
	} else {
		return tarForContents(
			[]byte(fmt.Sprintf(`{"FoundationId": "%s", "CollectedAt": "2006-01-02T15:04:05Z07:00"}`, foundationId)),
			path.Join("opsmanager", "metadata"),
		)
	}
}

func gzippedTarForContents(contents []byte, fileName string) []byte {
	buffer := &bytes.Buffer{}
	writer := gzip.NewWriter(buffer)
	_, _ = writer.Write(tarForContents(contents, fileName))
	writer.Close()

	return buffer.Bytes()
}

func tarForContents(contents []byte, fileName string) []byte {
	tarBuffer := bytes.NewBuffer([]byte{})
	tWriter := tar.NewWriter(tarBuffer)
	fileHeader := &tar.Header{
		Name: fileName,
		Size: int64(len(contents)),
		Mode: 0644,
	}
	Expect(tWriter.WriteHeader(fileHeader)).To(Succeed())
	_, err := tWriter.Write(contents)
	Expect(err).NotTo(HaveOccurred())

	tWriter.Close()

	return tarBuffer.Bytes()
}
