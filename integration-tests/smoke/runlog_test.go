package smoke

import (
	"context"
	"fmt"
	"github.com/google/uuid"
	"github.com/onsi/gomega"
	"github.com/smartcontractkit/chainlink-testing-framework/utils"
	"github.com/smartcontractkit/chainlink/integration-tests/client"
	"github.com/smartcontractkit/chainlink/integration-tests/docker/test_env"
	"github.com/stretchr/testify/require"
	"math/big"
	"strings"
	"testing"
)

func TestRunLogBasic(t *testing.T) {
	t.Parallel()
	l := utils.GetTestLogger(t)
	env, err := test_env.NewCLTestEnvBuilder().
		WithGeth().
		WithMockServer(1).
		WithCLNodes(1).
		Build()
	require.NoError(t, err)

	err = env.FundChainlinkNodes(big.NewFloat(.01))
	require.NoError(t, err, "Funding chainlink nodes with ETH shouldn't fail")

	lt, err := env.Geth.ContractDeployer.DeployLinkTokenContract()
	require.NoError(t, err, "Deploying Link Token Contract shouldn't fail")
	oracle, err := env.Geth.ContractDeployer.DeployOracle(lt.Address())
	require.NoError(t, err, "Deploying Oracle Contract shouldn't fail")
	consumer, err := env.Geth.ContractDeployer.DeployAPIConsumer(lt.Address())
	require.NoError(t, err, "Deploying Consumer Contract shouldn't fail")
	err = env.Geth.EthClient.SetDefaultWallet(0)
	require.NoError(t, err, "Setting default wallet shouldn't fail")
	err = lt.Transfer(consumer.Address(), big.NewInt(2e18))
	require.NoError(t, err, "Transferring %d to consumer contract shouldn't fail", big.NewInt(2e18))

	err = env.MockServer.Client.SetValuePath("/variable", 5)
	require.NoError(t, err, "Setting mockserver value path shouldn't fail")

	jobUUID := uuid.New()

	bta := client.BridgeTypeAttributes{
		Name: fmt.Sprintf("five-%s", jobUUID.String()),
		URL:  fmt.Sprintf("%s/variable", env.MockServer.Client.Config.ClusterURL),
	}
	err = env.CLNodes[0].API.MustCreateBridge(&bta)
	require.NoError(t, err, "Creating bridge shouldn't fail")

	os := &client.DirectRequestTxPipelineSpec{
		BridgeTypeAttributes: bta,
		DataPath:             "data,result",
	}
	ost, err := os.String()
	require.NoError(t, err, "Building observation source spec shouldn't fail")

	_, err = env.CLNodes[0].API.MustCreateJob(&client.DirectRequestJobSpec{
		Name:                     fmt.Sprintf("direct-request-%s", uuid.NewString()),
		MinIncomingConfirmations: "1",
		ContractAddress:          oracle.Address(),
		ExternalJobID:            jobUUID.String(),
		ObservationSource:        ost,
	})
	require.NoError(t, err, "Creating direct_request job shouldn't fail")

	jobUUIDReplaces := strings.Replace(jobUUID.String(), "-", "", 4)
	var jobID [32]byte
	copy(jobID[:], jobUUIDReplaces)
	err = consumer.CreateRequestTo(
		oracle.Address(),
		jobID,
		big.NewInt(1e18),
		fmt.Sprintf("%s/variable", env.MockServer.Client.Config.ClusterURL),
		"data,result",
		big.NewInt(100),
	)
	require.NoError(t, err, "Calling oracle contract shouldn't fail")

	gom := gomega.NewGomegaWithT(t)
	gom.Eventually(func(g gomega.Gomega) {
		d, err := consumer.Data(context.Background())
		g.Expect(err).ShouldNot(gomega.HaveOccurred(), "Getting data from consumer contract shouldn't fail")
		g.Expect(d).ShouldNot(gomega.BeNil(), "Expected the initial on chain data to be nil")
		l.Debug().Int64("Data", d.Int64()).Msg("Found on chain")
		g.Expect(d.Int64()).Should(gomega.BeNumerically("==", 5), "Expected the on-chain data to be 5, but found %d", d.Int64())
	}, "2m", "1s").Should(gomega.Succeed())
}
