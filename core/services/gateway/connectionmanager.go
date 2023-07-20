package gateway

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"

	"github.com/gorilla/websocket"
	"go.uber.org/multierr"

	"github.com/smartcontractkit/chainlink/v2/core/logger"
	"github.com/smartcontractkit/chainlink/v2/core/services/gateway/api"
	"github.com/smartcontractkit/chainlink/v2/core/services/gateway/common"
	"github.com/smartcontractkit/chainlink/v2/core/services/gateway/config"
	"github.com/smartcontractkit/chainlink/v2/core/services/gateway/handlers"
	"github.com/smartcontractkit/chainlink/v2/core/services/gateway/network"
	"github.com/smartcontractkit/chainlink/v2/core/services/job"
	"github.com/smartcontractkit/chainlink/v2/core/utils"
)

// ConnectionManager holds all connections between Gateway and Nodes.
type ConnectionManager interface {
	job.ServiceCtx
	network.ConnectionAcceptor

	DONConnectionManager(donId string) *donConnectionManager
}

type connectionManager struct {
	utils.StartStopOnce

	config             *config.ConnectionManagerConfig
	dons               map[string]*donConnectionManager
	wsServer           network.WebSocketServer
	clock              utils.Clock
	connAttempts       map[string]*connAttempt
	connAttemptCounter uint64
	connAttemptsMu     sync.Mutex
	lggr               logger.Logger
}

type donConnectionManager struct {
	donConfig  *config.DONConfig
	nodes      map[string]*nodeState
	handler    handlers.Handler
	codec      api.Codec
	closeWait  sync.WaitGroup
	shutdownCh chan struct{}
	lggr       logger.Logger
}

type nodeState struct {
	conn network.WSConnectionWrapper
}

// immutable
type connAttempt struct {
	nodeState   *nodeState
	nodeAddress string
	challenge   network.ChallengeElems
	timestamp   uint32
}

func NewConnectionManager(gwConfig *config.GatewayConfig, clock utils.Clock, lggr logger.Logger) (ConnectionManager, error) {
	codec := &api.JsonRPCCodec{}
	dons := make(map[string]*donConnectionManager)
	for _, donConfig := range gwConfig.Dons {
		donConfig := donConfig
		if donConfig.DonId == "" {
			return nil, errors.New("empty DON ID")
		}
		_, ok := dons[donConfig.DonId]
		if ok {
			return nil, fmt.Errorf("duplicate DON ID %s", donConfig.DonId)
		}
		nodes := make(map[string]*nodeState)
		for _, nodeConfig := range donConfig.Members {
			_, ok := nodes[nodeConfig.Address]
			if ok {
				return nil, fmt.Errorf("duplicate node address %s in DON %s", nodeConfig.Address, donConfig.DonId)
			}
			nodes[nodeConfig.Address] = &nodeState{conn: network.NewWSConnectionWrapper()}
		}
		dons[donConfig.DonId] = &donConnectionManager{
			donConfig:  &donConfig,
			codec:      codec,
			nodes:      nodes,
			shutdownCh: make(chan struct{}),
			lggr:       lggr,
		}
	}
	connMgr := &connectionManager{
		config:       &gwConfig.ConnectionManagerConfig,
		dons:         dons,
		connAttempts: make(map[string]*connAttempt),
		clock:        clock,
		lggr:         lggr.Named("ConnectionManager"),
	}
	wsServer := network.NewWebSocketServer(&gwConfig.NodeServerConfig, connMgr, lggr)
	connMgr.wsServer = wsServer
	return connMgr, nil
}

func (m *connectionManager) DONConnectionManager(donId string) *donConnectionManager {
	return m.dons[donId]
}

func (m *connectionManager) Start(ctx context.Context) error {
	return m.StartOnce("ConnectionManager", func() error {
		m.lggr.Info("starting connection manager")
		for _, donConnMgr := range m.dons {
			donConnMgr.closeWait.Add(len(donConnMgr.nodes))
			for nodeAddress, nodeState := range donConnMgr.nodes {
				if err := nodeState.conn.Start(); err != nil {
					return err
				}
				go donConnMgr.readLoop(nodeAddress, nodeState)
			}
		}
		return m.wsServer.Start(ctx)
	})
}

func (m *connectionManager) Close() error {
	return m.StopOnce("ConnectionManager", func() (err error) {
		m.lggr.Info("closing connection manager")
		err = multierr.Combine(err, m.wsServer.Close())
		for _, donConnMgr := range m.dons {
			close(donConnMgr.shutdownCh)
			for _, nodeState := range donConnMgr.nodes {
				nodeState.conn.Close()
			}
		}
		for _, donConnMgr := range m.dons {
			donConnMgr.closeWait.Wait()
		}
		return
	})
}

func (m *connectionManager) StartHandshake(authHeader []byte) (attemptId string, challenge []byte, err error) {
	m.lggr.Debug("StartHandshake")
	authHeaderElems, signer, err := network.UnpackSignedAuthHeader(authHeader)
	if err != nil {
		return "", nil, multierr.Append(network.ErrAuthHeaderParse, err)
	}
	nodeAddress := "0x" + hex.EncodeToString(signer)
	donConnMgr, ok := m.dons[authHeaderElems.DonId]
	if !ok {
		return "", nil, network.ErrAuthInvalidDonId
	}
	nodeState, ok := donConnMgr.nodes[nodeAddress]
	if !ok {
		return "", nil, network.ErrAuthInvalidNode
	}
	if authHeaderElems.GatewayId != m.config.AuthGatewayId {
		return "", nil, network.ErrAuthInvalidGateway
	}
	nowTs := uint32(m.clock.Now().Unix())
	ts := authHeaderElems.Timestamp
	if ts < nowTs-m.config.AuthTimestampToleranceSec || nowTs+m.config.AuthTimestampToleranceSec < ts {
		return "", nil, network.ErrAuthInvalidTimestamp
	}
	attemptId, challenge, err = m.newAttempt(nodeState, nodeAddress, ts)
	if err != nil {
		return "", nil, err
	}
	return attemptId, challenge, nil
}

func (m *connectionManager) newAttempt(nodeSt *nodeState, nodeAddress string, timestamp uint32) (string, []byte, error) {
	challengeBytes := make([]byte, m.config.AuthChallengeLen)
	_, err := rand.Read(challengeBytes)
	if err != nil {
		return "", nil, err
	}
	challenge := network.ChallengeElems{Timestamp: timestamp, GatewayId: m.config.AuthGatewayId, ChallengeBytes: challengeBytes}
	m.connAttemptsMu.Lock()
	defer m.connAttemptsMu.Unlock()
	m.connAttemptCounter++
	newId := fmt.Sprintf("%s_%d", nodeAddress, m.connAttemptCounter)
	m.connAttempts[newId] = &connAttempt{nodeState: nodeSt, nodeAddress: nodeAddress, challenge: challenge, timestamp: timestamp}
	return newId, network.PackChallenge(&challenge), nil
}

func (m *connectionManager) FinalizeHandshake(attemptId string, response []byte, conn *websocket.Conn) error {
	m.lggr.Debugw("FinalizeHandshake", "attemptId", attemptId)
	m.connAttemptsMu.Lock()
	attempt, ok := m.connAttempts[attemptId]
	delete(m.connAttempts, attemptId)
	m.connAttemptsMu.Unlock()
	if !ok {
		return network.ErrChallengeAttemptNotFound
	}
	signer, err := common.ExtractSigner(response, network.PackChallenge(&attempt.challenge))
	if err != nil || attempt.nodeAddress != "0x"+hex.EncodeToString(signer) {
		return network.ErrChallengeInvalidSignature
	}
	attempt.nodeState.conn.Reset(conn)
	m.lggr.Infof("node %s connected", attempt.nodeAddress)
	return nil
}

func (m *connectionManager) AbortHandshake(attemptId string) {
	m.lggr.Debugw("AbortHandshake", "attemptId", attemptId)
	m.connAttemptsMu.Lock()
	defer m.connAttemptsMu.Unlock()
	delete(m.connAttempts, attemptId)
}

func (m *donConnectionManager) SetHandler(handler handlers.Handler) {
	m.handler = handler
}

func (m *donConnectionManager) SendToNode(ctx context.Context, nodeAddress string, msg *api.Message) error {
	data, err := m.codec.EncodeRequest(msg)
	if err != nil {
		return fmt.Errorf("error encoding request for node %s: %v", nodeAddress, err)
	}
	return m.nodes[nodeAddress].conn.Write(ctx, websocket.BinaryMessage, data)
}

func (m *donConnectionManager) readLoop(nodeAddress string, nodeState *nodeState) {
	ctx, _ := utils.StopChan(m.shutdownCh).NewCtx()
	for {
		select {
		case <-m.shutdownCh:
			m.closeWait.Done()
			return
		case item := <-nodeState.conn.ReadChannel():
			msg, err := m.codec.DecodeResponse(item.Data)
			if err != nil {
				m.lggr.Errorw("parse error when reading from node", "nodeAddress", nodeAddress, "err", err)
				break
			}
			if err = msg.Validate(); err != nil {
				m.lggr.Errorw("message validation error when reading from node", "nodeAddress", nodeAddress, "err", err)
				break
			}
			err = m.handler.HandleNodeMessage(ctx, msg, nodeAddress)
			if err != nil {
				m.lggr.Error("error when calling HandleNodeMessage ", err)
			}
		}
	}
}
